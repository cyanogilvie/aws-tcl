# AWS signature version 4: https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html
# All services support version 4, except SimpleDB which requires version 2

package require rl_http 1.24
package require Thread
package require tomcrypt 0.9.2
package require parse_args
package require tdom
package require rl_json 0.17
package require chantricks
package require reuri 0.15.0

namespace eval aws {
	namespace export *
	# Note: we can't use -map for foreach/lmap because specifying -map disables
	# auto-resolution of exported procs (which this ensemble relies on for
	# commands like `aws from_camel`, `aws endpoint`, etc.). Route them via the
	# -unknown handler instead; it fires for any subcommand not already an
	# exported proc, which works because `foreach` and `lmap` are not procs in
	# this namespace (they'd shadow the builtins inside namespace-scoped code).
	namespace ensemble create -prefixes no -unknown {apply {
		{cmd subcmd args} {
			switch -- $subcmd {
				foreach { return [list ::aws::_foreach] }
				lmap    { return [list ::aws::_lmap] }
				default { package require aws::$subcmd; return }
			}
		}
	}}

	variable debug			false

	# default_region is initialised after the helpers namespace is defined
	# (see the `variable default_region` block below the `namespace eval helpers`).
	variable dir	[file dirname [file normalize [info script]]]
	variable endpoint_cache	{}

	namespace eval helpers {
		variable cache {}
		variable creds

		namespace path {
			::rl_json
			::parse_args
			::aws
		}

		# Retry / rate-limit configuration <<<
		#
		# Rate-limit state is kept in process-scoped tsv arrays because
		# rl_http's keepalive pool also crosses interp/thread boundaries:
		# a SlowDown observed on a socket that later gets pulled by
		# another interp must influence sends from that interp too. See
		# tsv keys:
		#   aws_tcl_rate       - per-service {max_rate next_send last_throttle}
		#   aws_tcl_rate_cfg   - shared config (retry mode, max attempts)
		# All rate-limit reads/writes are serialized via tsv::lock on
		# aws_tcl_rate.
		# retry_mode / max_attempts default to "" and are populated on first
		# access by _resolve_retry_config, which checks env vars first, then
		# the active profile in ~/.aws/config, then falls back to SDK defaults.
		# Callers can still override by setting the vars explicitly.
		variable retry_mode		""
		variable max_attempts	""

		# Retry classifier tables (merged from botocore _retry.json per-service
		# policies plus the SDK-wide transient set). Membership in either
		# table means the error is retryable; the distinction (throttle vs
		# transient) drives backoff behavior and rate-limit adjustment.
		variable _throttle_codes {
			Throttling ThrottlingException ThrottledException
			RequestThrottledException RequestThrottled
			TooManyRequestsException ProvisionedThroughputExceededException
			TransactionInProgressException RequestLimitExceeded
			BandwidthLimitExceeded LimitExceededException
			SlowDown PriorRequestNotComplete EC2ThrottledException
		}
		variable _transient_codes {
			InternalError InternalFailure InternalServerError
			InternalServerException ServiceUnavailable BadGateway
			GatewayTimeout RequestTimeout RequestTimeoutException
			IDPCommunicationError RequestTimeTooSkewed
		}
		# HTTP statuses that are always retryable regardless of parsed body
		variable _retry_statuses {408 425 429 500 502 503 504 509}

		# HTTP transport defaults. Three budgets, matching the shape
		# of botocore / Java SDK v2 defaults and exposed by rl_http 1.22:
		#
		#   request_timeout : overall request budget (rl_http -timeout).
		#     Matters for thread-exhaustion containment: bounds the
		#     worst-case time this proc can hold a thread when a remote
		#     endpoint gets wedged. 60s matches botocore defaults-mode
		#     standard (read_timeout=60s) and the AWS CLI's default.
		#   connect_timeout : cap on DNS+TCP+TLS handshake (rl_http
		#     -connect_timeout). 5s: halfway between Java v2's 2s and
		#     botocore's 60s; tolerates cross-region TCP handshake
		#     latency without masking a dead IP.
		#   read_timeout : cap on each inter-readable-chunk wait
		#     (rl_http -read_timeout). Resets on each chunk, so this
		#     is "max silent gap" during the body stream. 30s matches
		#     Java SDK v2.
		#
		# request_timeout is the hard ceiling. connect_timeout and
		# read_timeout can only shorten it, not extend, so raising
		# request_timeout for a streaming Lambda invoke (e.g. 900s)
		# while keeping read_timeout=30s is the canonical pattern:
		# 15-minute function, fail if 30s elapse between chunks.
		variable request_timeout		[if {[info exists ::env(AWSTCL_REQUEST_TIMEOUT)]} {
			set ::env(AWSTCL_REQUEST_TIMEOUT)
		} else { return -level 0 60 }]
		variable connect_timeout		[if {[info exists ::env(AWSTCL_CONNECT_TIMEOUT)]} {
			set ::env(AWSTCL_CONNECT_TIMEOUT)
		} else { return -level 0 5 }]
		variable read_timeout			[if {[info exists ::env(AWSTCL_READ_TIMEOUT)]} {
			set ::env(AWSTCL_READ_TIMEOUT)
		} else { return -level 0 30 }]
		# -max_keepalive_age bounds how long a pooled keepalive
		# connection may live in the parking tsv before being forced
		# to reconnect. Setting a cap here (rather than rl_http's
		# default of no limit) matters for S3/DynamoDB scaling: those
		# services scale via new partitions and fronting IPs, and a
		# stubbornly reused connection sticks to stale capacity even
		# after the service has scaled up to absorb the caller's
		# load. 60s matches the Java SDK v2 connectionMaxIdleTime
		# and lets the resolve-cache TTL (also 60s in rl_http) and
		# the S3 scale-up interval align.
		variable max_keepalive_age		[if {[info exists ::env(AWSTCL_MAX_KEEPALIVE_AGE)]} {
			set ::env(AWSTCL_MAX_KEEPALIVE_AGE)
		} else { return -level 0 60 }]
		variable max_keepalive_count	-1
		# Upper bound on exponential backoff (seconds). Matches botocore.
		variable _backoff_cap		20.0
		variable _backoff_base		0.5
		# Per-service rate-limit bucket bootstrap state
		variable _max_send_rate		50.0
		# Minimum floor for the adaptive send-rate cap (Hz)
		variable _min_send_rate		0.5

		if {[llength [tsv::names aws_tcl_rate]] == 0} {
			# No-op: tsv::names is cheap; ensures the array exists lazily
		}
		# Retry / rate-limit configuration >>>

		interp alias {} ::aws::helpers::sigencode {} ::reuri encode awssig

		tomcrypt::prng create prng {}

		proc _cache {cachekey script} { #<<<
			variable cache
			if {![dict exists $cache $cachekey]} {
				dict set cache $cachekey [uplevel 1 $script]
			}

			dict get $cache $cachekey
		}

		#>>>
		proc _debug script { #<<<
			variable ::aws::debug
			if {$debug} {uplevel 1 $script}
		}

		#>>>
		# Config / credentials file resolution. These mirror the AWS CLI
		# rules for locating and reading ~/.aws/config and ~/.aws/credentials,
		# and for picking the active profile.
		proc _profile_name {} { #<<<
			global env
			if {[info exists env(AWS_PROFILE)] && $env(AWS_PROFILE) ne ""} {
				return $env(AWS_PROFILE)
			}
			if {[info exists env(AWS_DEFAULT_PROFILE)] && $env(AWS_DEFAULT_PROFILE) ne ""} {
				return $env(AWS_DEFAULT_PROFILE)
			}
			return default
		}

		#>>>
		proc _expand_path path { #<<<
			if {$path eq ""} {return ""}
			# file normalize expands leading ~ via Tcl's filename-resolution rules.
			file normalize $path
		}

		#>>>
		proc _config_file_path {} { #<<<
			global env
			if {[info exists env(AWS_CONFIG_FILE)] && $env(AWS_CONFIG_FILE) ne ""} {
				return [_expand_path $env(AWS_CONFIG_FILE)]
			}
			if {[info exists env(HOME)]} {
				return [file join $env(HOME) .aws/config]
			}
			return ""
		}

		#>>>
		proc _credentials_file_path {} { #<<<
			global env
			if {[info exists env(AWS_SHARED_CREDENTIALS_FILE)] && $env(AWS_SHARED_CREDENTIALS_FILE) ne ""} {
				return [_expand_path $env(AWS_SHARED_CREDENTIALS_FILE)]
			}
			if {[info exists env(HOME)]} {
				return [file join $env(HOME) .aws/credentials]
			}
			return ""
		}

		#>>>
		proc _ini_section_keys {path section} { #<<<
			# Return a dict of key→value for the given INI section, or {} if
			# the file is unreadable or the section is absent.
			if {$path eq "" || ![file readable $path]} {return {}}
			set in_sect	0
			set result	{}
			set h	[open $path r]
			try {
				chan configure $h -translation auto
				while {[gets $h line] >= 0} {
					switch -regexp -matchvar m -- [string trim $line] {
						"^;#"			continue
						{^\[(.*)\]$}	{
							set in_sect		[expr {[lindex $m 1] eq $section}]
						}
						{^([^=]+)\s*=\s*(.*?)(?:\s+[#;].*)?$} {
							if {$in_sect} {
								lassign $m - k v
								set k	[string trim $k]
								set v	[string trim $v]
								dict set result $k $v
							}
						}
					}
				}
				set result
			} finally {
				close $h
			}
		}

		#>>>
		proc _config_profile_keys {{profile {}}} { #<<<
			if {$profile eq ""} {set profile [_profile_name]}
			set section	[expr {$profile eq "default" ? "default" : "profile $profile"}]
			_ini_section_keys [_config_file_path] $section
		}

		#>>>
		proc _credentials_profile_keys {{profile {}}} { #<<<
			if {$profile eq ""} {set profile [_profile_name]}
			# The credentials file uses bare profile names, no "profile " prefix.
			_ini_section_keys [_credentials_file_path] $profile
		}

		#>>>
		proc _profile_value {key {profile {}}} { #<<<
			# Credentials-file entry takes precedence over config-file entry
			# for the same key. Returns "" when neither file has it.
			set creds	[_credentials_profile_keys $profile]
			if {[dict exists $creds $key]} {return [dict get $creds $key]}
			set cfg		[_config_profile_keys $profile]
			if {[dict exists $cfg $key]} {return [dict get $cfg $key]}
			return ""
		}

		#>>>
		proc _endpoint_url_override service { #<<<
			# Resolve AWS_ENDPOINT_URL-style overrides for the given service.
			# Precedence (CLI-compatible, strongest first):
			#   1. AWS_ENDPOINT_URL_<SERVICE>
			#   2. AWS_ENDPOINT_URL
			#   3. active profile's services.<id>.<svc>.endpoint_url
			#      (requires a services = <id> key in the profile)
			#   4. active profile's endpoint_url
			# Returns the URL string, or "" if no override applies.
			global env

			# Convert service id to env var suffix (s3 -> S3, dynamodb -> DYNAMODB,
			# transcribe-streaming -> TRANSCRIBE_STREAMING).
			set svc_env [string toupper [string map {- _} $service]]
			if {[info exists env(AWS_ENDPOINT_URL_$svc_env)] && $env(AWS_ENDPOINT_URL_$svc_env) ne ""} {
				return $env(AWS_ENDPOINT_URL_$svc_env)
			}
			if {[info exists env(AWS_ENDPOINT_URL)] && $env(AWS_ENDPOINT_URL) ne ""} {
				return $env(AWS_ENDPOINT_URL)
			}
			set profile_cfg [_config_profile_keys]
			if {[dict exists $profile_cfg services]} {
				set services_section "services [dict get $profile_cfg services]"
				set svc_keys [_ini_section_keys [_config_file_path] $services_section]
				# keys look like "<svc> endpoint_url" but inifile flattens
				# the "svc = ..." group — the CLI uses a nested syntax we can
				# approximate by matching "<svc>.endpoint_url" or storing under
				# a compound key. We try the literal compound key first.
				if {[dict exists $svc_keys "$service.endpoint_url"]} {
					return [dict get $svc_keys "$service.endpoint_url"]
				}
			}
			if {[dict exists $profile_cfg endpoint_url]} {
				return [dict get $profile_cfg endpoint_url]
			}
			return ""
		}

		#>>>
		proc _apply_endpoint_override {endpoint_info_var service} { #<<<
			# Mutate endpoint_info in place to apply any AWS_ENDPOINT_URL*
			# override. Preserves signing region / credential scope from the
			# rule-engine result; overrides only transport fields (scheme,
			# host, port).
			upvar 1 $endpoint_info_var ei
			set url [_endpoint_url_override $service]
			if {$url eq ""} {return}
			set scheme [reuri get $url scheme http]
			set host   [reuri get $url host]
			set port   [reuri get $url port ""]
			if {$port ne ""} {set host $host:$port}
			dict set ei hostname $host
			dict set ei protocols [list $scheme]
			# Drop sslCommonName — it would override hostname for https but
			# is meaningless against a user-supplied endpoint.
			dict unset ei sslCommonName
			_debug {log notice "endpoint override for $service: $url -> scheme=$scheme host=$host"}
		}

		#>>>
		proc _config_bool {key default_val} { #<<<
			# Read a boolean config value (env var first, then profile) using
			# CLI-style truthy matching (true/1/yes/on, case-insensitive).
			global env
			set env_name [string toupper $key]
			if {[info exists env(AWS_$env_name)]} {
				set raw $env(AWS_$env_name)
			} else {
				set raw [_profile_value [string tolower $key]]
			}
			if {$raw eq ""} {return $default_val}
			return [expr {[string tolower $raw] in {true 1 yes on}}]
		}

		#>>>
		proc _ca_bundle {} { #<<<
			# Resolve AWS_CA_BUNDLE / active profile ca_bundle, or "" if unset.
			# Returns the path to a PEM bundle suitable for passing to
			# rl_http's -cafile option (1.24+).
			global env
			if {[info exists env(AWS_CA_BUNDLE)] && $env(AWS_CA_BUNDLE) ne ""} {
				return $env(AWS_CA_BUNDLE)
			}
			return [_profile_value ca_bundle]
		}

		#>>>
		proc _resolve_retry_config {} { #<<<
			# Populate retry_mode / max_attempts from env or active profile
			# if they haven't been set yet. Idempotent.
			global env
			variable retry_mode
			variable max_attempts
			if {$retry_mode eq ""} {
				if {[info exists env(AWS_RETRY_MODE)] && $env(AWS_RETRY_MODE) ne ""} {
					set retry_mode $env(AWS_RETRY_MODE)
				} else {
					set v [_profile_value retry_mode]
					set retry_mode [expr {$v ne "" ? $v : "standard"}]
				}
			}
			if {$max_attempts eq ""} {
				if {[info exists env(AWS_MAX_ATTEMPTS)] && $env(AWS_MAX_ATTEMPTS) ne ""} {
					set max_attempts $env(AWS_MAX_ATTEMPTS)
				} else {
					set v [_profile_value max_attempts]
					set max_attempts [expr {$v ne "" ? $v : 3}]
				}
			}
		}

		#>>>

		proc _sleep_ms ms { #<<<
			# Sleep for $ms milliseconds without entering a nested event
			# loop. Two paths:
			#   1. Coroutine: schedule a wakeup with after, yield. On
			#      coroutine teardown the after is cancelled via a trace.
			#   2. Plain script: block the thread on a per-thread
			#      cond+mutex using thread::cond wait's built-in timeout.
			#      The cond is private to this thread so nobody else can
			#      notify it; the wait returns purely via the timeout.
			#      No vwait, so no re-entrant event processing.
			#
			# Callers that need the event loop to keep servicing other
			# work during the delay should use a coroutine (e.g. via
			# aio::coro_sleep at the outer level).
			if {$ms <= 0} return
			if {[info coroutine] ne ""} {
				set aid [after $ms [info coroutine]]
				set cleanup [list apply {{id old new op} {
					after cancel $id
				}} $aid]
				trace add command [info coroutine] delete $cleanup
				try {
					yield
				} finally {
					trace remove command [info coroutine] delete $cleanup
				}
				return
			}
			variable _sleep_mutex
			variable _sleep_cond
			if {![info exists _sleep_mutex]} {
				set _sleep_mutex	[thread::mutex create]
				set _sleep_cond		[thread::cond  create]
			}
			thread::mutex lock $_sleep_mutex
			try {
				thread::cond wait $_sleep_cond $_sleep_mutex $ms
			} finally {
				thread::mutex unlock $_sleep_mutex
			}
		}

		#>>>
		proc _uuid4 {} { #<<<
			# UUIDv4 suitable for idempotency tokens. Random bytes come from
			# libtomcrypt's CSPRNG; version (4) and variant (10xx) nibbles
			# are set per RFC 4122.
			set bytes	[prng bytes 16]
			binary scan $bytes cu16 b
			lset b 6	[expr {([lindex $b 6] & 0x0f) | 0x40}]
			lset b 8	[expr {([lindex $b 8] & 0x3f) | 0x80}]
			set hex	[binary encode hex [binary format c16 $b]]
			return	[string range $hex 0 7]-[string range $hex 8 11]-[string range $hex 12 15]-[string range $hex 16 19]-[string range $hex 20 31]
		}

		#>>>
		proc _backoff_ms {attempt {base {}} {cap {}}} { #<<<
			# Exponential backoff with full jitter. attempt is 1-based.
			#   delay = rand(0, 1) * min(base * 2^(attempt-1), cap)
			# Matches botocore ExponentialBackoff and the AWS SDK v2/v3
			# "standard" retry mode. Returns delay in milliseconds.
			variable _backoff_cap
			variable _backoff_base
			if {$base eq ""} {set base $_backoff_base}
			if {$cap  eq ""} {set cap  $_backoff_cap}
			set ceiling	[expr {min($base * (2.0 ** ($attempt - 1)), $cap)}]
			expr {entier(rand() * $ceiling * 1000)}
		}

		#>>>
		proc _retry_after_ms headers { #<<<
			# Parse a Retry-After response header. Supports the delay-seconds
			# form (integer) and HTTP-date form; returns delay in ms, or ""
			# if the header is absent / unparseable. Non-negative only.
			if {![dict exists $headers retry-after]} return
			set v	[string trim [dict get $headers retry-after]]
			if {$v eq ""} return
			if {[string is integer -strict $v]} {
				if {$v < 0} return
				return [expr {$v * 1000}]
			}
			# HTTP-date (RFC 7231). clock scan handles most forms.
			if {[catch {clock scan $v -format "%a, %d %b %Y %H:%M:%S %Z"} t]} return
			set delta	[expr {$t - [clock seconds]}]
			if {$delta < 0} return
			expr {$delta * 1000}
		}

		#>>>
		proc _classify_error options { #<<<
			# Classify a caught error. Returns one of:
			#   {throttle <code>}  — server told us to slow down
			#   {transient <code>} — server hiccup or connection error, retry
			#   {clockskew <code>} — signing clock skew, retry after resync
			#   {none <code>}      — not retryable
			# $options is the dict from `on error` / `trap`.
			variable _throttle_codes
			variable _transient_codes
			variable _retry_statuses

			set ec		[dict get $options -errorcode]
			if {[lindex $ec 0] ne "AWS"} {
				# rl_http / socket / DNS / TLS errors — treat as transient
				return [list transient [lindex $ec 0]]
			}
			set code	[lindex $ec 1]
			if {$code eq "RequestTimeTooSkewed"} {
				return [list clockskew $code]
			}
			if {$code in $_throttle_codes} {
				return [list throttle $code]
			}
			if {$code in $_transient_codes} {
				return [list transient $code]
			}
			if {[string is integer -strict $code] && $code in $_retry_statuses} {
				return [expr {$code == 429 ? "throttle $code" : "transient $code"}]
			}
			return [list none $code]
		}

		#>>>
		proc _rate_before_send key { #<<<
			# Per-service rate-limit bucket. Keyed by a stable service id
			# (signingName if available, else host). State is a three-list
			# {max_rate next_send last_throttle}:
			#   max_rate        : current cap in Hz
			#   next_send       : earliest clock microseconds we may send
			#   last_throttle   : clock seconds of last observed throttle
			_resolve_retry_config
			variable _max_send_rate
			variable _min_send_rate
			variable retry_mode
			if {$retry_mode eq "legacy"} return	;# legacy mode = no send pacing

			set now_us	[clock microseconds]
			tsv::lock aws_tcl_rate {
				if {[tsv::exists aws_tcl_rate $key]} {
					lassign [tsv::get aws_tcl_rate $key] max_rate next_send last_throttle
					# In standard mode we still recover (grow) the rate after
					# a quiet period. Adaptive mode uses a stricter pacing.
					if {$max_rate < $_max_send_rate && [clock seconds] - $last_throttle > 10} {
						set max_rate	[expr {min($_max_send_rate, $max_rate + max(1.0, $max_rate * 0.5))}]
					}
				} else {
					set max_rate		$_max_send_rate
					set next_send		0
					set last_throttle	0
				}
				set wait_us		[expr {$next_send - $now_us}]
				set interval_us	[expr {entier(1.0e6 / $max_rate)}]
				set new_next	[expr {max($now_us, $next_send) + $interval_us}]
				tsv::set aws_tcl_rate $key [list $max_rate $new_next $last_throttle]
			}
			if {$wait_us > 0} {
				_sleep_ms [expr {$wait_us / 1000 + 1}]
			}
		}

		#>>>
		proc _rate_after_throttle key { #<<<
			variable _min_send_rate
			tsv::lock aws_tcl_rate {
				if {[tsv::exists aws_tcl_rate $key]} {
					lassign [tsv::get aws_tcl_rate $key] max_rate next_send _
				} else {
					variable _max_send_rate
					set max_rate	$_max_send_rate
					set next_send	0
				}
				set max_rate	[expr {max($_min_send_rate, $max_rate * 0.5)}]
				tsv::set aws_tcl_rate $key [list $max_rate $next_send [clock seconds]]
			}
		}

		#>>>
		proc _rate_key {sig_service region} { #<<<
			# Stable per-service key for the rate-limit bucket. Uses the
			# signing name + region; either may be empty for metadata endpoints.
			if {$sig_service eq ""} {set sig_service -}
			if {$region eq ""} {set region -}
			return $sig_service:$region
		}

		#>>>
		proc sign {K str} { #<<<
			# sigv2/s3: returns base64, consumed directly into an
			# Authorization header.
			binary encode base64 [tomcrypt::hmac sha1 $K [encoding convertto utf-8 $str]]
		}

		#>>>
		proc log {lvl msg {template {}}} { #<<<
			switch -exact -- [identify] {
				Lambda {
					if {$template ne ""} {
						set doc	[uplevel 1 [list json template $template]]
					} else {
						set doc {{}}
					}
					json set doc lvl [json new string $lvl]
					json set doc msg [json new string $msg]

					puts stderr $doc
				}

				default {
					if {$template ne ""} {
						append msg " " [json pretty [uplevel 1 [list json template $template]]]
					}
					puts stderr $msg
				}
			}
		}

		#>>>
		proc amz-date s { clock format $s -format %Y%m%d -timezone :UTC }
		proc amz-datetime s { clock format $s -format %Y%m%dT%H%M%SZ -timezone :UTC }
		namespace eval hash { #<<<
			namespace export *
			namespace ensemble create -prefixes no

			proc AWS4-HMAC-SHA256 bytes { #<<<
				# Caller expects hex — this feeds the x-amz-content-sha256
				# header which is part of the canonical request that
				# gets signed, and the server compares hex.
				binary encode hex [tomcrypt::hash sha256 $bytes]
			}

			#>>>
		}

		#>>>
		proc sigv2 args { #<<<
			global env

			parse_args::parse_args $args {
				-variant					{-enum {v2 s3} -default v2}
				-method						{-required}
				-service					{-required}
				-path						{-required}
				-scheme						{-default http}
				-headers					{-default {}}
				-params						{-default {}}
				-content_md5				{-default {}}
				-content_type				{-default {}}
				-body						{-default {}}
				-sig_service				{-default {}}
				-disable_double_encoding	{-default 0}
				-signing_region				{-default {}}

				-out_url					{-alias}
				-out_headers				{-alias}
				-out_sts					{-alias}
			}

			set creds		[get_creds]
			set aws_id		[dict get $creds access_key]
			set aws_key		[dict get $creds secret]
			set aws_token	[dict get $creds token]

			#if {$sig_service eq ""} {set sig_service $service}
			set method			[string toupper $method]
			set date			[clock format [clock seconds] -format {%a, %d %b %Y %H:%M:%S +0000} -timezone GMT]
			set amz_headers		{}
			set camz_headers	""
			lappend headers Date $date
			if {[info exists aws_token]} {
				lappend headers x-amz-security-token $aws_token
			}
			foreach {k v} $headers {
				set k	[string tolower $k]
				if {![string match x-amz-* $k]} continue
				dict lappend amz_headers $k $v
			}
			foreach k [lsort [dict keys $amz_headers]] {
				# TODO: protect against "," in header values per RFC 2616, section 4.2
				append camz_headers "$k:[join [dict get $amz_headers $k] ,]\n"
			}

			# Produce urlv: a list of fully decoded path elements, and canonized_path: a fully-encoded and normalized path <<<
			set urlv	{}
			if {[string trim $path /] eq ""} {
				set canonized_path	/
			} else {
				if {$disable_double_encoding} {
					set urlv	[split [string trim $path /] /]
				} else {
					set urlv	[lmap e [split [string trim $path /] /] {sigencode $e}]
				}
				set canonized_path	/[join [lmap e $urlv {sigencode $e}] /]
				if {[string index $path end] eq "/" && [string index $canonized_path end] ne "/"} {
					append canonized_path	/
				}
			}
			#>>>

			# Build resource <<<
			if {$sig_service ne ""} {
				set resource	/$sig_service$canonized_path
			} else {
				set resource	$canonized_path
			}
			set resource_params	{}
			foreach {k v} [lsort -index 0 -stride 2 $params] {
				if {$k in {acl lifecycle location logging notification partNumber policy requestPayment torrent uploadId uploads versionId versioning versions website
				response-content-type response-content-language response-expires response-cache-control response-content-disposition response-content-encoding
				delete
				}} continue

				# https://docs.aws.amazon.com/AmazonS3/latest/dev/RESTAuthentication.html#UsingTemporarySecurityCredentials says not to encode query string parameters in the resource
				if {$v eq ""} {
					lappend resource_params $k
				} else {
					lappend resource_params $k=$v
				}
			}
			if {[llength $resource_params] > 0} {
				append resource ?[join $resource_params &]
			}
			#>>>

			if {[llength $params]} {
				set eparams		{}
			} else {
				set eparams		?[join [lmap {k v} $params {format %s=%s [sigencode $k] [sigencode $v]}] &]
			}
			set out_url			$scheme://$service.amazonaws.com$canonized_path$eparams

			set string_to_sign	$method\n$content_md5\n$content_type\n$date\n$camz_headers$resource
			set auth	"AWS $aws_id:[sign $aws_key $string_to_sign]"

			#dict set headers Authorization	$auth	;# headers is not a dict - can contain multiple instances of a key!
			lappend headers Authorization $auth

			if {$content_md5 ne ""} {
				lappend headers Content-MD5 $content_md5
			}
			if {$content_type ne ""} {
				lappend headers Content-Type $content_type
			}

			set out_headers		$headers
			set out_sts			$string_to_sign
			#log notice "Sending aws request $method $signed_url\n$auth\n$string_to_sign"

		}

		#>>>
		proc sigv4_signing_key args { #<<<
			parse_args::parse_args $args {
				-aws_key		{-required}
				-date			{-required -# {in unix seconds}}
				-region			{-required}
				-service		{-required}
			}
			_debug {log notice "sigv4_signing_key, region: $region, service: $service"}

			set amzDate		[amz-date $date]
			set kDate		[tomcrypt::hmac sha256 [encoding convertto utf-8 AWS4$aws_key]	[encoding convertto utf-8 $amzDate]]
			set kRegion		[tomcrypt::hmac sha256 $kDate									[encoding convertto utf-8 $region]]
			set kService	[tomcrypt::hmac sha256 $kRegion									[encoding convertto utf-8 $service]]
			tomcrypt::hmac sha256 $kService aws4_request
		}

		#>>>
		# Shared canonicalization helpers for sigv4 / sigv4a <<<
		# All return pure data; no upvar, no side effects.

		proc _canonical_path {path do_normalize disable_double_encoding} { #<<<
			# Split, optionally normalize, and percent-encode $path into its
			# canonical forms. Returns {canonical_uri canonical_uri_sig}.
			# canonical_uri_sig double-encodes unless $disable_double_encoding.
			# When !$do_normalize (S3, MRAP) empty components are preserved so
			# repeated / trailing slashes survive reassembly.
			if {$path eq ""} {return {/ /}}
			# reuri::path get returns "/" as element 0 for an absolute
			# path and the decoded segments after. Drop the marker and
			# remember whether we need to re-prepend "/".
			set segs		[reuri::path get $path]
			set has_lead	[expr {[lindex $segs 0] eq "/"}]
			set urlv		[lrange $segs $has_lead end]
			if {!$do_normalize} {
				set n_urlv	$urlv
			} else {
				# TODO: properly normalize according to RFC 3986 §6 (doesn't apply to s3)
				set n_urlv			{}
				set had_trailing	0
				foreach e $urlv {
					switch -- $e {
						. - ""	{set had_trailing 1}
						..		{set n_urlv [lrange $n_urlv 0 end-1]}
						default	{lappend n_urlv $e; set had_trailing 0}
					}
				}
				if {$had_trailing} {lappend n_urlv ""}
			}
			set prefix	[expr {$has_lead ? "/" : ""}]
			set canonical_uri_sig	${prefix}[join [lmap e $n_urlv {
				if {$disable_double_encoding} {sigencode $e} else {sigencode [sigencode $e]}
			}] /]
			set canonical_uri		${prefix}[join [lmap e $n_urlv {sigencode $e}] /]
			if {$canonical_uri eq ""} {return {/ /}}
			list $canonical_uri $canonical_uri_sig
		}

		#>>>
		proc _canonical_query params { #<<<
			# Build the canonical query string: encode, sort by encoded key
			# (values as tiebreak), then k=v&... Empty value is still k=.
			if {[llength $params] == 0} {return ""}
			set paramsort {{a b} {
				set kc	[string compare [lindex $a 0] [lindex $b 0]]
				switch -- $kc {
					1 - -1	{ set kc }
					default { string compare [lindex $a 1] [lindex $b 1] }
				}
			}}
			set encoded	[lmap {k v} $params {list [sigencode $k] [sigencode $v]}]
			join [lmap e [lsort -command [list apply $paramsort] $encoded] {
				lassign $e ek ev
				format %s=%s $ek $ev
			}] &
		}

		#>>>
		proc _canonical_headers t_headers { #<<<
			# Build the canonical-headers block and signed-headers list from
			# a dict of name→list-of-values (case-insensitive key sort).
			# Returns {canonical_headers_block signed_headers_semi_joined}.
			set canonical_headers	""
			set signed_headers		{}
			foreach {k v} [lsort -index 0 -stride 2 -nocase $t_headers] {
				set h	[string tolower [string trim $k]]
				lappend signed_headers	$h
				append canonical_headers	"$h:[join [lmap e $v {regsub -all { +} [string trim $e] { }}] ,]\n"
			}
			list $canonical_headers [join $signed_headers ";"]
		}

		#>>>
		proc _url_query_tail params { #<<<
			# Encode $params as a ?k=v&... tail for the final request URL.
			# Empty-valued params are emitted as the bare key (no trailing =).
			if {![llength $params]} {return ""}
			string cat ? [join [lmap {k v} $params {
				if {$v eq ""} {
					sigencode $k
				} else {
					format %s=%s [sigencode $k] [sigencode $v]
				}
			}] &]
		}

		#>>>
		# Shared canonicalization helpers >>>
		proc sigv4 args { #<<<
			global env

			parse_args::parse_args $args {
				-variant					{-enum {v4 s3v4} -default v4}
				-method						{-required}
				-endpoint					{-required}
				-sig_service				{-default {}}
				-region						{-default us-east-1}
				-credential_scope			{-default ""}
				-disable_double_encoding	{-default 0}
				-signing_region				{-default {}}
				-path						{-required}
				-scheme						{-default http}
				-headers					{-default {}}
				-params						{-default {}}
				-content_type				{-default {}}
				-body						{-default {}}
				-algorithm					{-enum {AWS4-HMAC-SHA256} -default AWS4-HMAC-SHA256}
				-normalize					{-enum {auto true false} -default auto -# {auto = normalize unless sig_service is s3; explicit true/false overrides}}

				-out_url					{-alias}
				-out_headers				{-alias}
				-out_sts					{-alias}

				-date						{-# {Fake the date - for test suite}}
				-out_creq					{-alias -# {internal - used for test suite}}
				-out_authz					{-alias -# {internal - used for test suite}}
				-out_sreq					{-alias -# {internal - used for test suite}}
			}
			_debug {log notice "sigv4 args: $args"}

			if {$signing_region eq {}} {set signing_region	$region}

			set creds		[get_creds]
			set aws_id		[dict get $creds access_key]
			set aws_key		[dict get $creds secret]
			set aws_token	[if {[dict exists $creds token]} {dict get $creds token}]

			if {$sig_service eq ""} {
				set sig_service	$service
			}

			if {$credential_scope eq ""} {
				set credential_scope	$region
			}

			set have_date_header	0
			foreach {k v} $headers {
				if {[string tolower $k] eq "x-amz-date"} {
					set have_date_header	1
					set date	[clock scan $v -format %Y%m%dT%H%M%SZ -timezone :UTC]
				}
			}
			if {![info exists date]} {
				set date	[clock seconds]
			}

			# Task1: Compile canonical request <<<
			# Credential scope <<<
			set fq_credential_scope	[amz-date $date]/[string tolower $credential_scope/$sig_service/aws4_request]
			# Credential scope >>>

			# Canonical URI <<<
			# -normalize auto = skip normalization only for s3; true/false override.
			set do_normalize	[expr {$normalize eq "auto" ? ($sig_service ne "s3") : $normalize}]
			lassign [_canonical_path $path $do_normalize $disable_double_encoding] \
				canonical_uri canonical_uri_sig
			#>>>

			set canonical_query_string	[_canonical_query $params]

			# Canonical headers <<<
			set out_headers		$headers
			if {!$have_date_header} {
				lappend out_headers	x-amz-date	[amz-datetime $date]
			}
			if {
				"content-type" ni [lmap {k v} $out_headers {string tolower $k}] &&
				$content_type ne ""
			} {
				lappend out_headers content-type $content_type
			}
			if {"host" ni [lmap {k v} $out_headers {string tolower $k}]} {
				lappend out_headers host $endpoint		;# :authority for HTTP/2
			}
			if {$aws_token ne ""} {
				lappend out_headers X-Amz-Security-Token	$aws_token
			}

			if {$variant eq "s3v4"} {
				if {"x-amz-content-sha256" ni [lmap {k v} $headers {set k}]} {
					# TODO: consider caching the sha256 of the empty body
					if {$body eq ""} {
						lappend out_headers x-amz-content-sha256	UNSIGNED-PAYLOAD
					} else {
						lappend out_headers x-amz-content-sha256	[hash AWS4-HMAC-SHA256 $body]
					}
				}
			}

			set t_headers	{}
			foreach {k v} $out_headers {
				dict lappend t_headers $k $v
			}
			lassign [_canonical_headers $t_headers] canonical_headers signed_headers
			# Canonical headers >>>

			foreach {k v} $t_headers {
				if {$k ne "x-amz-content-sha256"} continue
				set hashed_payload $v
			}
			if {![info exists hashed_payload]} {
				set hashed_payload	[hash $algorithm $body]
			}

			set canonical_request	"[string toupper $method]\n$canonical_uri_sig\n$canonical_query_string\n$canonical_headers\n$signed_headers\n$hashed_payload"
			#log debug "canonical request" {{"creq": "~S:canonical_request"}}
			_debug {
				puts stderr "canonical request:\n$canonical_request"
			}
			set hashed_canonical_request	[hash $algorithm $canonical_request]
			set out_creq	$canonical_request
			# Task1: Compile canonical request >>>

			# Task2: Create String to Sign <<<
			set string_to_sign	[encoding convertto utf-8 $algorithm]\n[amz-datetime $date]\n[encoding convertto utf-8 $fq_credential_scope]\n$hashed_canonical_request
			set out_sts		$string_to_sign
			#log notice "sts:\n$out_sts"
			#puts stderr "sts:\n$out_sts"
			# Task2: Create String to Sign >>>

			# Task3: Calculate signature <<<
			set signing_key	[sigv4_signing_key -aws_key $aws_key -date $date -region $signing_region -service $sig_service]
			set signature	[binary encode hex [tomcrypt::hmac sha256 $signing_key [encoding convertto utf-8 $string_to_sign]]]
			#puts stderr "sig:\n$signature"
			# Task3: Calculate signature >>>


			set authorization	"$algorithm Credential=$aws_id/$fq_credential_scope, SignedHeaders=$signed_headers, Signature=$signature"
			set out_authz		$authorization
			lappend out_headers	Authorization $authorization

			set out_url		$scheme://$endpoint$canonical_uri[_url_query_tail $params]
		}

		#>>>
		# SigV4-A: ECDSA over P-256. Multi-region-capable successor to
		# sigv4 used by a handful of services (S3 Multi-Region Access
		# Points, some Cognito / EventBridge / STS flows). Key
		# differences from sigv4:
		#   - credential scope omits the region component
		#   - algorithm name: AWS4-ECDSA-P256-SHA256
		#   - signing key is a P-256 scalar derived from the secret
		#     access key via NIST SP 800-108 counter-mode KDF
		#   - signing op is ECDSA-sign-hash, not HMAC
		#   - X-Amz-Region-Set header lists the regions (or "*") the
		#     signature is valid for
		#   - signature is hex of the ANSI X9.62 DER-encoded (r,s)
		variable _sigv4a_p256_n \
			[scan ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551 %llx]

		proc _derive_sigv4a_scalar {aws_key aws_id} { #<<<
			# NIST SP 800-108 counter-mode KDF with HMAC-SHA256,
			# producing a P-256 scalar from "AWS4A" || secret_access_key.
			# Layout matches aws-c-auth's key_derivation.c:
			#
			#   FixedInput = 0x00000001
			#              || "AWS4-ECDSA-P256-SHA256"
			#              || 0x00
			#              || AccessKeyId
			#              || counter (single byte)
			#              || 0x00000100           ; uint32_be(256) = output bits
			#
			# Iterate counter 1..254. Interpret HMAC output as a big-endian
			# 256-bit int c. If c ≤ n-2 accept: private scalar = c + 1.
			# First iteration succeeds ~100% of the time in practice.
			variable _sigv4a_p256_n

			set kdf_key			[encoding convertto utf-8 AWS4A$aws_key]
			set prefix_bytes	[binary format I 1]		;# uint32_be(1) — fixed placeholder
			set label_bytes		AWS4-ECDSA-P256-SHA256
			set id_bytes		[encoding convertto utf-8 $aws_id]
			set length_bytes	[binary format I 256]	;# uint32_be(256) — output bits

			set n_minus_2	[expr {$_sigv4a_p256_n - 2}]

			for {set counter 1} {$counter <= 254} {incr counter} {
				set counter_byte	[binary format c $counter]
				set fixed_input		$prefix_bytes$label_bytes\x00$id_bytes$counter_byte$length_bytes
				set c_bytes			[tomcrypt::hmac sha256 $kdf_key $fixed_input]
				# scan %llx is the bignum-safe parser; `expr 0x<hex>`
				# silently truncates to 128 bits for 64-hex-char strings
				# in Tcl 9.
				set c	[scan [binary encode hex $c_bytes] %llx]
				if {$c <= $n_minus_2} {
					return [binary decode hex [format %064llx [expr {$c + 1}]]]
				}
			}
			throw {AWS SIGV4A KDF_EXHAUSTED} \
				"SigV4-A KDF failed to produce a valid scalar in 254 iterations"
		}

		#>>>
		proc sigv4a args { #<<<
			global env

			parse_args::parse_args $args {
				-variant					{-enum {v4a s3v4a} -default v4a}
				-method						{-required}
				-endpoint					{-required}
				-sig_service				{-default {}}
				-region						{-default us-east-1 -# {only used for hostname/endpoint selection; signature is region-agnostic}}
				-region_set					{-default *}
				-disable_double_encoding	{-default 0}
				-path						{-required}
				-scheme						{-default http}
				-headers					{-default {}}
				-params						{-default {}}
				-content_type				{-default {}}
				-body						{-default {}}
				-normalize					{-enum {auto true false} -default auto -# {auto = normalize unless sig_service is s3; explicit true/false overrides}}

				-out_url					{-alias}
				-out_headers				{-alias}
				-out_sts					{-alias}

				-date						{-# {Fake the date - for test suite}}
				-out_creq					{-alias -# {internal - used for test suite}}
				-out_authz					{-alias -# {internal - used for test suite}}
				-out_sreq					{-alias -# {internal - used for test suite}}
			}
			_debug {log notice "sigv4a args: $args"}

			set algorithm	AWS4-ECDSA-P256-SHA256

			set creds		[get_creds]
			set aws_id		[dict get $creds access_key]
			set aws_key		[dict get $creds secret]
			set aws_token	[if {[dict exists $creds token]} {dict get $creds token}]

			if {$sig_service eq ""} {
				throw {AWS SIGV4A MISSING_SIG_SERVICE} \
					"sigv4a: -sig_service is required"
			}
			set region_set_header	[join $region_set ,]

			set have_date_header	0
			foreach {k v} $headers {
				if {[string tolower $k] eq "x-amz-date"} {
					set have_date_header	1
					set date	[clock scan $v -format %Y%m%dT%H%M%SZ -timezone :UTC]
				}
			}
			if {![info exists date]} {
				set date	[clock seconds]
			}

			# v4a credential scope — no region
			set fq_credential_scope	[amz-date $date]/$sig_service/aws4_request

			# Canonical URI <<<
			set do_normalize	[expr {$normalize eq "auto" ? ($sig_service ne "s3") : $normalize}]
			lassign [_canonical_path $path $do_normalize $disable_double_encoding] \
				canonical_uri canonical_uri_sig
			#>>>

			set canonical_query_string	[_canonical_query $params]

			# Canonical headers, with the v4a-required X-Amz-Region-Set <<<
			set out_headers		$headers
			if {!$have_date_header} {
				lappend out_headers	x-amz-date	[amz-datetime $date]
			}
			if {"x-amz-region-set" ni [lmap {k v} $out_headers {string tolower $k}]} {
				lappend out_headers X-Amz-Region-Set $region_set_header
			}
			if {
				"content-type" ni [lmap {k v} $out_headers {string tolower $k}] &&
				$content_type ne ""
			} {
				lappend out_headers content-type $content_type
			}
			if {"host" ni [lmap {k v} $out_headers {string tolower $k}]} {
				lappend out_headers host $endpoint
			}
			if {$aws_token ne ""} {
				lappend out_headers X-Amz-Security-Token	$aws_token
			}

			# s3v4a variant: S3 ops that use UNSIGNED-PAYLOAD
			if {$variant eq "s3v4a"} {
				if {"x-amz-content-sha256" ni [lmap {k v} $headers {set k}]} {
					if {$body eq ""} {
						lappend out_headers x-amz-content-sha256	UNSIGNED-PAYLOAD
					} else {
						lappend out_headers x-amz-content-sha256	[hash AWS4-HMAC-SHA256 $body]
					}
				}
			}

			set t_headers	{}
			foreach {k v} $out_headers {
				dict lappend t_headers $k $v
			}
			lassign [_canonical_headers $t_headers] canonical_headers signed_headers
			# Canonical headers >>>

			foreach {k v} $t_headers {
				if {$k ne "x-amz-content-sha256"} continue
				set hashed_payload $v
			}
			if {![info exists hashed_payload]} {
				set hashed_payload	[hash AWS4-HMAC-SHA256 $body]
			}

			set canonical_request	"[string toupper $method]\n$canonical_uri_sig\n$canonical_query_string\n$canonical_headers\n$signed_headers\n$hashed_payload"
			_debug {puts stderr "canonical request (v4a):\n$canonical_request"}
			set hashed_canonical_request	[hash AWS4-HMAC-SHA256 $canonical_request]
			set out_creq	$canonical_request

			set string_to_sign	[encoding convertto utf-8 $algorithm]\n[amz-datetime $date]\n[encoding convertto utf-8 $fq_credential_scope]\n$hashed_canonical_request
			set out_sts		$string_to_sign
			_debug {puts stderr "sts (v4a):\n$out_sts"}

			# Task3: ECDSA sign <<<
			set sts_hash	[tomcrypt::hash sha256 [encoding convertto utf-8 $string_to_sign]]
			set priv_scalar	[_derive_sigv4a_scalar $aws_key $aws_id]
			set priv_key	[tomcrypt::ecc_import_raw_private secp256r1 $priv_scalar]
			set signature	[binary encode hex [tomcrypt::ecc_sign $priv_key $sts_hash]]
			# Task3 >>>

			set authorization	"$algorithm Credential=$aws_id/$fq_credential_scope, SignedHeaders=$signed_headers, Signature=$signature"
			set out_authz		$authorization
			lappend out_headers	Authorization $authorization

			set out_url		$scheme://$endpoint$canonical_uri[_url_query_tail $params]
		}

		#>>>
		proc _aws_error {h xml_ns string_to_sign} { #<<<
			if {[$h body] eq ""} {
				throw [list AWS [$h code]] "AWS http code [$h code]"
			}
			if {[string match "\{*" [$h body]]} { # Guess json <<<
				if {[json exists [$h body] code]} {
					# TODO: use [json get [$h body] type]
					throw [list AWS \
						[json get [$h body] code] \
						[dict get [$h headers] x-amzn-requestid] \
						"" \
					] [json get [$h body] message]
				} elseif {[json exists [$h body] __type]} {
					if {[json exists [$h body] message]} {
						set message	[json get [$h body] message]
					} else {
						set message	"AWS exception: [json get [$h body] __type]"
					}
					throw [list AWS \
						[json get [$h body] __type] \
						[dict get [$h headers] x-amzn-requestid] \
						"" \
					] $message
				} elseif {[json exists [$h body] message]} {
					set headers	[$h headers]
					throw [list AWS \
						[if {[dict exists $headers x-amzn-errortype]} {dict get $headers x-amzn-errortype} else {return -level 0 "<unknown>"}] \
						[dict get [$h headers] x-amzn-requestid] \
						"" \
					] [json get [$h body] message]
				} else {
					set headers	[$h headers]
					log error "Unhandled AWS error: [$h body]"
					throw [list AWS \
						[if {[dict exists $headers x-amzn-errortype]} {dict get $headers x-amzn-errortype} else {return -level 0 "<unknown>"}] \
						[dict get [$h headers] x-amzn-requestid] \
						"" \
					] "Unhandled AWS error type"
				}
				#>>>
			} else { # Guess XML <<<
				dom parse -ignorexmlns [$h body] doc
				try {
					if {$xml_ns ne ""} {
						$doc selectNodesNamespaces [list a $xml_ns]
					}
					$doc documentElement root
					#log notice "AWS error:\n[$root asXML -indent 4]"
					# EC2 wraps errors as <Response><Errors><Error>...</Error></Errors><RequestID>...</RequestID></Response>
					if {[$root nodeName] eq "Response" && [$root selectNodes {string(Errors/Error/Code)}] ne ""} {
						set err		[lindex [$root selectNodes Errors/Error] 0]
						set details	{}
						foreach node [$err childNodes] {
							lappend details [$node nodeName] [$node text]
						}
						throw [list AWS \
							[$err selectNodes string(Code)] \
							[$root selectNodes string(RequestID)] \
							"" \
							$details \
						] "AWS: [$err selectNodes string(Message)]"
					} elseif {[$root nodeName] eq "Error"} {
						set details	{}
						foreach node [$root childNodes] {
							lappend details [$node nodeName] [$node text]
						}
						throw [list AWS \
							[$root selectNodes string(Code)] \
							[$root selectNodes string(RequestId)] \
							[$root selectNodes string(Resource)] \
							$details \
						] "AWS: [$root selectNodes string(Message)]"
					} elseif {[$root nodeName] eq "ErrorResponse" && [$root selectNodes {string(Error/Code)}] ne ""} {
						# CloudFormation / query protocol wraps errors as
						# <ErrorResponse><Error>...</Error><RequestId>...</RequestId></ErrorResponse>
						set err		[lindex [$root selectNodes Error] 0]
						set details	{}
						foreach node [$err childNodes] {
							lappend details [$node nodeName] [$node text]
						}
						throw [list AWS \
							[$err selectNodes string(Code)] \
							[$root selectNodes string(RequestId)] \
							"" \
							$details \
						] "AWS: [$err selectNodes string(Message)]"
					} else {
						log error "Error parsing AWS error response:\n[$h body]"
						throw [list AWS [$h code]] "Error parsing [$h code] error response from AWS"
					}
				} trap {AWS SignatureDoesNotMatch} {errmsg options} {
					set signed_hex	[regexp -all -inline .. [binary encode hex [encoding convertto utf-8 $string_to_sign]]]
					set wanted_hex	[$root selectNodes string(StringToSignBytes)]
					set wanted_str	[encoding convertto utf-8 [binary decode hex [$root selectNodes string(StringToSignBytes)]]]
					log error "AWS signing error" {
						{
							"hex": {
								"signed":"~S:signed_hex",
								"wanted":"~S:wanted_hex"
							},
							"str": {
								"signed":"~S:string_to_sign",
								"wanted":"~S:wanted_str"
							}
						}
					}
					return -options $options $errmsg
				} trap {AWS} {errmsg options} {
					return -options $options $errmsg
				} on error {errmsg options} {
					log error "Unhandled AWS error: [dict get $options -errorinfo]"
					throw {AWS UNKNOWN} $errmsg
				} finally {
					$doc delete
				}
				#>>>
			}
		}

		#>>>
		proc _req {method endpoint path args} { #<<<
			parse_args::parse_args $args {
				-scheme						{-default http}
				-headers					{-default {}}
				-params						{-default {}}
				-content_type				{-default {}}
				-body						{-default {}}
				-xml_ns						{-default {}}
				-response_headers			{-alias}
				-status						{-alias}
				-sig_service				{-default {}}
				-version					{-enum {v4 v2 s3 s3v4 v4a s3v4a} -default v4 -# {AWS signature version}}
				-region						{-required}
				-credential_scope			{-default ""}
				-disable_double_encoding	{-default 0}
				-signing_region				{-default {}}
				-expecting_status			{-default 200}
				-timeout					{-default {}}
				-connect_timeout			{-default {}}
				-read_timeout				{-default {}}
				-max_keepalive_age			{-default {}}
				-max_keepalive_count		{-default {}}
			}
			# Resolve transport defaults from the helpers-level config
			# vars (overridable via env — see variable declarations).
			if {$timeout eq ""} {
				set timeout				[set ::aws::helpers::request_timeout]
			}
			if {$connect_timeout eq ""} {
				set connect_timeout		[set ::aws::helpers::connect_timeout]
			}
			if {$read_timeout eq ""} {
				set read_timeout		[set ::aws::helpers::read_timeout]
			}
			if {$max_keepalive_age eq ""} {
				set max_keepalive_age	[set ::aws::helpers::max_keepalive_age]
			}
			if {$max_keepalive_count eq ""} {
				set max_keepalive_count	[set ::aws::helpers::max_keepalive_count]
			}
			if {[reuri exists $path query]} {
				set q		[reuri extract $path query]
				set path	[reuri extract $path path]
				if {$path eq ""} {set path /}
				foreach {k v} $params {
					reuri::query set q $k $v
				}
				set params	[reuri::query get $q]
			}

			switch -- $version {
				s3 - v2 {
					sigv2 \
						-variant					$version \
						-method						$method \
						-service					$service \
						-path						$path \
						-scheme						$scheme \
						-headers					$headers \
						-params						$params \
						-content_type				$content_type \
						-body						$body \
						-sig_service				$sig_service \
						-disable_double_encoding	$disable_double_encoding \
						-signing_region				$signing_region \
						-out_url					signed_url \
						-out_headers				signed_headers \
						-out_sts					string_to_sign
				}

				v4 - s3v4 {
					sigv4 \
						-variant					$version \
						-method						$method \
						-endpoint					$endpoint \
						-sig_service				$sig_service \
						-region						$region \
						-path						$path \
						-scheme						$scheme \
						-headers					$headers \
						-params						$params \
						-content_type				$content_type \
						-body						$body \
						-credential_scope			$credential_scope \
						-disable_double_encoding	$disable_double_encoding \
						-signing_region				$signing_region \
						-out_url					signed_url \
						-out_headers				signed_headers \
						-out_sts					string_to_sign
				}

				v4a - s3v4a {
					sigv4a \
						-variant					$version \
						-method						$method \
						-endpoint					$endpoint \
						-sig_service				$sig_service \
						-region						$region \
						-path						$path \
						-scheme						$scheme \
						-headers					$headers \
						-params						$params \
						-content_type				$content_type \
						-body						$body \
						-disable_double_encoding	$disable_double_encoding \
						-out_url					signed_url \
						-out_headers				signed_headers \
						-out_sts					string_to_sign
				}

				default {
					error "Unhandled signature version \"$version\""
				}
			}

			_debug {
				log debug "AWS req" {
					{
						"scheme":			"~S:scheme",
						"method":			"~S:method",
						"endpoint":			"~S:endpoint",
						"path":				"~S:path",
						"content_type":		"~S:content_type",
						"sig_version":		"~S:version",
						"signed_url":		"~S:signed_url",
						"signed_headers":	"~S:signed_headers",
						"string_to_sign":	"~S:string_to_sign"
					}
				}
			}

			if 0 {
			set bodysize	[string length $body]
			log notice "Making AWS request" {
				{
					"method": "~S:method",
					"signed_url": "~S:signed_url",
					"signed_headers": "~S:signed_headers",
					"headers": "~S:headers",
					//"body": "~S:body",
					"bodySize": "~N:bodysize"
				}
			}
			}
			#puts stderr "rl_http $method $signed_url -headers [list $signed_headers] -data [list $body]"
			set ca_bundle	[_ca_bundle]
			set extra	[if {$::aws::debug} {
				package require chantricks
				list -tapchan [list ::chantricks::tapchan [list apply {
					{name chan op args} {
						::aws::helpers::_debug {
							set ts		[clock microseconds]
							set s		[expr {$ts / 1000000}]
							set tail	[string trimleft [format %.6f [expr {($ts % 1000000) / 1e6}]] 0]
							set ts_str	[clock format $s -format "%Y-%m-%dT%H:%M:%S" -timezone :UTC]${tail}Z
							switch -exact -- $op {
								read - write {
									lassign $args bytes
									puts stderr "$ts_str $op $name [binary encode hex $bytes]"
								}
								initialize - finalize - drain - flush {
									puts stderr "$ts_str $op $name"
								}
								default {
									puts stderr "$ts_str $op $name (unexpected)"
								}
							}
						}
					}
				}] rl_http_$signed_url]
			}]
			rl_http instvar h $method $signed_url \
				-timeout				$timeout \
				-connect_timeout		$connect_timeout \
				-read_timeout			$read_timeout \
				-keepalive				1 \
				-max_keepalive_age		$max_keepalive_age \
				-max_keepalive_count	$max_keepalive_count \
				-headers				$signed_headers \
				{*}[expr {$ca_bundle ne "" ? [list -cafile $ca_bundle] : {}}] \
				{*}$extra \
				-data					$body

			#puts stderr "rl_http $method $signed_url, headers: ($signed_headers), data: ($body)"
			#puts stderr "got [$h code] headers: ([$h headers])\n[$h body]"

			#log notice "aws req $method $signed_url response [$h code]\n\t[join [lmap {k v} [$h headers] {format {%s: %s} $k $v}] \n\t]\nbody: [$h body]"

			set status				[$h code]
			set response_headers	[$h headers]
			if {[$h code] == $expecting_status} {
				return [$h body]
			} else {
				#puts stderr "Got [$h code]:\n\theaders: ([$h headers])\n\tbody: ([$h body])"
				_aws_error $h $xml_ns $string_to_sign
			}
		}

		#>>>
		proc _aws_req {method endpoint path args} { #<<<
			_resolve_retry_config
			variable max_attempts
			variable retry_mode

			parse_args::parse_args $args {
				-scheme						{-default http}
				-headers					{-default {}}
				-params						{-default {}}
				-content_type				{-default {}}
				-body						{-default {}}
				-xml_ns						{-default {}}
				-response_headers			{-alias}
				-status						{-alias}
				-sig_service				{-default {}}
				-version					{-enum {v4 v2 s3 s3v4 v4a s3v4a} -default v4 -# {AWS signature version}}
				-retries					{-default {}}
				-region						{-required}
				-credential_scope			{-default ""}
				-disable_double_encoding	{-default 0}
				-signing_region				{-default {}}
				-expecting_status			{-default 200}
				-timeout					{-default {}}
				-connect_timeout			{-default {}}
				-read_timeout				{-default {}}
				-max_keepalive_age			{-default {}}
				-max_keepalive_count		{-default {}}
			}
			# -retries stays for backward compat; if unspecified we use the
			# configured default (AWS_MAX_ATTEMPTS / the variable).
			if {$retries eq ""} {set retries $max_attempts}
			set rate_key	[_rate_key $sig_service $region]

			for {set try 1} {$try <= $retries} {incr try} {
				_rate_before_send $rate_key
				try {
					return [_req $method $endpoint $path \
						-region						$region \
						-credential_scope			$credential_scope \
						-disable_double_encoding	$disable_double_encoding \
						-signing_region				$signing_region \
						-expecting_status			$expecting_status \
						-headers					$headers \
						-params						$params \
						-content_type				$content_type \
						-body						$body \
						-response_headers			response_headers \
						-status						status \
						-scheme						$scheme \
						-xml_ns						$xml_ns \
						-sig_service				$sig_service \
						-version					$version \
						-timeout					$timeout \
						-connect_timeout			$connect_timeout \
						-read_timeout				$read_timeout \
						-max_keepalive_age			$max_keepalive_age \
						-max_keepalive_count		$max_keepalive_count \
					]
				} on error {errmsg options} {
					lassign [_classify_error $options] kind code
					if {$kind eq "none" || $try >= $retries} {
						return -options $options $errmsg
					}

					# Honour Retry-After when provided, else full-jitter
					# exponential backoff capped at _backoff_cap seconds.
					set retry_after_ms	""
					if {[info exists response_headers]} {
						set retry_after_ms	[_retry_after_ms $response_headers]
					}
					set delay_ms	[expr {
						$retry_after_ms ne "" ? $retry_after_ms : [_backoff_ms $try]
					}]

					if {$kind eq "throttle"} {
						_rate_after_throttle $rate_key
						log notice "aws req got throttle ($code), backoff ${delay_ms}ms (attempt $try/$retries)"
					} elseif {$kind eq "clockskew"} {
						# TODO: resync the signing clock. For now fall
						# through to the transient path — a short wait
						# and retry will often fix transient skew.
						log notice "aws req got RequestTimeTooSkewed, backoff ${delay_ms}ms (attempt $try/$retries)"
					} else {
						log notice "aws req transient error ($code), backoff ${delay_ms}ms (attempt $try/$retries)"
					}
					_sleep_ms $delay_ms
					continue
				}
			}

			# Unreachable — the final attempt's error is returned via
			# `return -options` above. Guard against logic bugs.
			throw {AWS TOO_MANY_ERRORS} "Too many errors, ran out of patience retrying"
		}

		#>>>

		proc instance_identity {} { #<<<
			_cache instance_identity {
				_metadata dynamic/instance-identity/document
			}
		}

		#>>>
		proc get_creds {} { #<<<
			# Resolves credentials the way the AWS CLI does, in this order:
			#   1. A per-thread override pushed by _with_creds (used by AssumeRole
			#      nested STS calls to avoid recursing through the chain).
			#   2. A static override set via aws::set_creds.
			#   3. Env vars: AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY (+optional
			#      AWS_SESSION_TOKEN). Never cached — refreshed from env each call.
			#   4. Env-var web-identity: AWS_ROLE_ARN + AWS_WEB_IDENTITY_TOKEN_FILE.
			#   5. The active profile. For each profile we try in order:
			#        a. credential_process
			#        b. role_arn + web_identity_token_file (AssumeRoleWithWebIdentity)
			#        c. role_arn + source_profile OR credential_source (AssumeRole)
			#        d. sso_session / sso_start_url (not yet implemented)
			#        e. static aws_access_key_id / aws_secret_access_key
			#   6. Container creds: AWS_CONTAINER_CREDENTIALS_RELATIVE_URI or
			#      AWS_CONTAINER_CREDENTIALS_FULL_URI (+ optional auth token).
			#   7. EC2 IMDS (v2 preferred, v1 fallback unless disabled).
			global env
			variable creds
			variable _cred_override

			# 1. per-thread override (for nested STS calls)
			if {[info exists _cred_override] && [llength $_cred_override] > 0} {
				return [lindex $_cred_override end]
			}

			# 2. static override via set_creds, or a prior-call cached chain result
			if {
				[info exists creds] &&
				[dict exists $creds expires] &&
				[dict get $creds expires] - [clock seconds] < 60
			} {
				unset creds
			}
			if {[info exists creds]} {return $creds}

			# 3. env vars (never cached)
			if {
				[info exists env(AWS_ACCESS_KEY_ID)] &&
				$env(AWS_ACCESS_KEY_ID) ne "" &&
				[info exists env(AWS_SECRET_ACCESS_KEY)]
			} {
				set tmp [dict create \
					access_key	$env(AWS_ACCESS_KEY_ID) \
					secret		$env(AWS_SECRET_ACCESS_KEY) \
					source		env \
				]
				if {[info exists env(AWS_SESSION_TOKEN)]} {
					dict set tmp token $env(AWS_SESSION_TOKEN)
				}
				_debug {log debug "Found credentials: env"}
				return $tmp
			}

			# 4. env-var web identity (IRSA / EKS Pod Identity token mode)
			if {
				[info exists env(AWS_ROLE_ARN)] && $env(AWS_ROLE_ARN) ne "" &&
				[info exists env(AWS_WEB_IDENTITY_TOKEN_FILE)] && $env(AWS_WEB_IDENTITY_TOKEN_FILE) ne ""
			} {
				set role_session [expr {
					[info exists env(AWS_ROLE_SESSION_NAME)] && $env(AWS_ROLE_SESSION_NAME) ne ""
					? $env(AWS_ROLE_SESSION_NAME)
					: "aws-tcl-[_uuid4]"
				}]
				set creds [_web_identity_creds \
					$env(AWS_ROLE_ARN) $env(AWS_WEB_IDENTITY_TOKEN_FILE) $role_session]
				_debug {log debug "Found credentials: web_identity (env)"}
				return $creds
			}

			# 5. active profile
			try {
				set creds [_resolve_profile_creds [_profile_name] {}]
				_debug {log debug "Found credentials: profile [_profile_name] ([dict get $creds source])"}
				return $creds
			} trap {AWS NO_PROFILE_CREDS} {} {
				# profile isn't configured for static/process/role/sso —
				# fall through to container/IMDS
				unset -nocomplain creds
			}

			# 6. container creds (ECS RELATIVE_URI or EKS FULL_URI)
			if {
				[info exists env(AWS_CONTAINER_CREDENTIALS_RELATIVE_URI)] ||
				[info exists env(AWS_CONTAINER_CREDENTIALS_FULL_URI)]
			} {
				try {
					set role_creds [_container_creds]
					set creds [_creds_from_sts_json $role_creds container]
					_debug {log debug "Found credentials: container"}
					return $creds
				} on error {msg opts} {
					_debug {log warn "Container credentials fetch failed: $msg"}
					unset -nocomplain creds
				}
			}

			# 7. EC2 instance metadata
			if {![_imds_disabled]} {
				try {
					set role_creds [instance_role_creds]
					set creds [_creds_from_sts_json $role_creds instance_role]
					_debug {log debug "Found credentials: instance_role"}
					return $creds
				} on error {} {
					unset -nocomplain creds
				}
			}

			throw {AWS NO_CREDENTIALS} "No credentials were supplied or could be found"
		}

		#>>>
		proc _creds_from_sts_json {role_creds source} { #<<<
			# role_creds is a JSON doc with AccessKeyId / SecretAccessKey / Token /
			# expires_sec (epoch seconds, pre-parsed from Expiration).
			set out [dict create \
				access_key	[json get $role_creds AccessKeyId] \
				secret		[json get $role_creds SecretAccessKey] \
				token		[json get $role_creds Token] \
				source		$source \
			]
			if {[json exists $role_creds expires_sec]} {
				dict set out expires [json get $role_creds expires_sec]
			}
			return $out
		}

		#>>>
		proc set_creds args { #<<<
			variable creds

			parse_args $args {
				-access_key		{-required}
				-secret			{-required}
				-token			{-default {}}
			} creds
		}

		#>>>
		proc _with_creds {creds script} { #<<<
			# Push $creds onto the override stack, evaluate $script in the
			# caller's scope, then pop. Used by the AssumeRole / web-identity
			# paths so the nested sts:AssumeRole(WithWebIdentity) call signs
			# with the source creds instead of recursing through get_creds.
			variable _cred_override
			if {![info exists _cred_override]} {set _cred_override {}}
			lappend _cred_override $creds
			try {
				uplevel 1 $script
			} finally {
				set _cred_override [lrange $_cred_override 0 end-1]
			}
		}

		#>>>
		proc _resolve_profile_creds {profile visited} { #<<<
			# Recursive resolver for named-profile credential sources.
			# Returns a creds dict or throws {AWS NO_PROFILE_CREDS} if the
			# profile exists but has nothing resolvable, or {AWS PROFILE_CYCLE}
			# on source_profile cycles.
			if {$profile in $visited} {
				throw {AWS PROFILE_CYCLE} "source_profile cycle detected: [list $profile {*}$visited]"
			}
			lappend visited $profile

			set cfg		[_config_profile_keys $profile]
			set cred	[_credentials_profile_keys $profile]
			# Merge: credentials-file keys override config-file keys.
			set merged	[dict merge $cfg $cred]

			if {[dict size $merged] == 0} {
				throw {AWS NO_PROFILE_CREDS} "profile '$profile' not found in config or credentials file"
			}

			# a. credential_process
			if {[dict exists $merged credential_process]} {
				return [_credential_process_creds [dict get $merged credential_process]]
			}

			# b. web-identity via profile
			if {
				[dict exists $merged role_arn] &&
				[dict exists $merged web_identity_token_file]
			} {
				set session [expr {
					[dict exists $merged role_session_name]
					? [dict get $merged role_session_name]
					: "aws-tcl-[_uuid4]"
				}]
				return [_web_identity_creds \
					[dict get $merged role_arn] \
					[dict get $merged web_identity_token_file] \
					$session]
			}

			# c. AssumeRole via source_profile or credential_source
			if {[dict exists $merged role_arn]} {
				if {[dict exists $merged source_profile]} {
					set source_profile	[dict get $merged source_profile]
					set source_creds	[_resolve_profile_creds $source_profile $visited]
				} elseif {[dict exists $merged credential_source]} {
					set source_creds	[_creds_from_source [dict get $merged credential_source]]
				} else {
					throw {AWS PROFILE_INVALID} "profile '$profile' has role_arn but no source_profile or credential_source"
				}
				if {[dict exists $merged mfa_serial]} {
					throw {AWS UNSUPPORTED} "profile '$profile' requires MFA (mfa_serial); aws-tcl does not prompt — obtain a session token with the AWS CLI and export it via env vars"
				}
				set session [expr {
					[dict exists $merged role_session_name]
					? [dict get $merged role_session_name]
					: "aws-tcl-[_uuid4]"
				}]
				set duration [expr {
					[dict exists $merged duration_seconds]
					? [dict get $merged duration_seconds]
					: 3600
				}]
				set external_id [expr {
					[dict exists $merged external_id]
					? [dict get $merged external_id]
					: ""
				}]
				return [_assume_role_creds \
					$source_creds \
					[dict get $merged role_arn] \
					$session $duration $external_id]
			}

			# d. SSO / IAM Identity Center — modern sso_session or legacy
			# sso_start_url on the profile. We read the token cache that
			# `aws sso login` maintains; we do not run the device-code
			# login flow ourselves. Token refresh via refreshToken is
			# supported.
			if {[dict exists $merged sso_session]} {
				return [_sso_creds_from_session $profile $merged]
			}
			if {[dict exists $merged sso_start_url]} {
				return [_sso_creds_from_legacy $profile $merged]
			}

			# e. static access_key / secret_key
			if {
				[dict exists $merged aws_access_key_id] &&
				[dict exists $merged aws_secret_access_key]
			} {
				set out [dict create \
					access_key	[dict get $merged aws_access_key_id] \
					secret		[dict get $merged aws_secret_access_key] \
					source		"profile:$profile" \
				]
				if {[dict exists $merged aws_session_token]} {
					dict set out token [dict get $merged aws_session_token]
				}
				return $out
			}

			throw {AWS NO_PROFILE_CREDS} "profile '$profile' has no resolvable credential source"
		}

		#>>>
		proc _creds_from_source source { #<<<
			# credential_source = Environment | Ec2InstanceMetadata | EcsContainer
			global env
			switch -- $source {
				Environment {
					if {
						![info exists env(AWS_ACCESS_KEY_ID)] ||
						![info exists env(AWS_SECRET_ACCESS_KEY)]
					} {
						throw {AWS NO_CREDENTIALS} "credential_source=Environment but AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY not set"
					}
					set out [dict create \
						access_key	$env(AWS_ACCESS_KEY_ID) \
						secret		$env(AWS_SECRET_ACCESS_KEY) \
						source		env \
					]
					if {[info exists env(AWS_SESSION_TOKEN)]} {
						dict set out token $env(AWS_SESSION_TOKEN)
					}
					return $out
				}
				Ec2InstanceMetadata {
					return [_creds_from_sts_json [instance_role_creds] instance_role]
				}
				EcsContainer {
					return [_creds_from_sts_json [_container_creds] container]
				}
				default {
					throw {AWS PROFILE_INVALID} "unknown credential_source: $source"
				}
			}
		}

		#>>>
		proc _credential_process_creds command { #<<<
			# Run the configured credential_process command. Returns a creds dict
			# including an 'expires' epoch when Expiration is present. The command
			# is parsed as a shell-style string per the AWS spec — supports
			# "foo --bar baz" without invoking a real shell.
			# Tcl's exec with {*}[split ...] would be wrong for quoted args, so
			# we go via `sh -c` to match CLI behaviour on POSIX.
			try {
				set out [exec sh -c $command 2>/dev/null]
			} on error {msg opts} {
				throw {AWS CREDENTIAL_PROCESS} "credential_process failed: $msg"
			}
			try {
				set j $out
				if {[json get $j Version] != 1} {
					throw {AWS CREDENTIAL_PROCESS} "credential_process returned Version != 1"
				}
				set result [dict create \
					access_key	[json get $j AccessKeyId] \
					secret		[json get $j SecretAccessKey] \
					source		credential_process \
				]
				if {[json exists $j SessionToken]} {
					dict set result token [json get $j SessionToken]
				}
				if {[json exists $j Expiration]} {
					dict set result expires [clock scan [json get $j Expiration] -timezone :UTC -format {%Y-%m-%dT%H:%M:%SZ}]
				}
				return $result
			} on error {msg opts} {
				throw {AWS CREDENTIAL_PROCESS} "credential_process output unparseable: $msg"
			}
		}

		#>>>
		proc _assume_role_creds {source_creds role_arn session_name duration external_id} { #<<<
			# Nest-call sts:AssumeRole using $source_creds. Runs through the
			# normal operation dispatcher so endpoint rules, retries, etc. all
			# still apply; _with_creds short-circuits the credential chain
			# while this runs.
			variable ::aws::default_region
			package require aws::sts
			set args [list \
				-RoleArn $role_arn \
				-RoleSessionName $session_name \
				-DurationSeconds $duration \
				-region $::aws::default_region]
			if {$external_id ne ""} {lappend args -ExternalId $external_id}
			_with_creds $source_creds {
				set resp [aws sts assume_role {*}$args]
			}
			set j [json extract $resp Credentials]
			return [dict create \
				access_key	[json get $j AccessKeyId] \
				secret		[json get $j SecretAccessKey] \
				token		[json get $j SessionToken] \
				expires		[clock scan [json get $j Expiration] -timezone :UTC -format {%Y-%m-%dT%H:%M:%SZ}] \
				source		"assume-role:$role_arn" \
			]
		}

		#>>>
		proc _web_identity_creds {role_arn token_file session_name} { #<<<
			# Nest-call sts:AssumeRoleWithWebIdentity. This operation is
			# anonymous (noAuth) so no source credentials are needed.
			variable ::aws::default_region
			package require aws::sts
			set fh [open $token_file r]
			try {
				set token [read $fh]
			} finally {
				close $fh
			}
			set token [string trim $token]
			set resp [aws sts assume_role_with_web_identity \
				-RoleArn $role_arn \
				-RoleSessionName $session_name \
				-WebIdentityToken $token \
				-region $::aws::default_region]
			set j [json extract $resp Credentials]
			return [dict create \
				access_key	[json get $j AccessKeyId] \
				secret		[json get $j SecretAccessKey] \
				token		[json get $j SessionToken] \
				expires		[clock scan [json get $j Expiration] -timezone :UTC -format {%Y-%m-%dT%H:%M:%SZ}] \
				source		"web-identity:$role_arn" \
			]
		}

		#>>>
		proc _sso_creds_from_session {profile merged} { #<<<
			# Modern sso-session form. Profile carries sso_session=NAME +
			# sso_account_id + sso_role_name; the [sso-session NAME]
			# section in ~/.aws/config carries sso_start_url, sso_region,
			# sso_registration_scopes. Token cache filename is sha1(NAME).
			foreach k {sso_session sso_account_id sso_role_name} {
				if {![dict exists $merged $k]} {
					throw {AWS PROFILE_INVALID} "profile '$profile' is missing $k"
				}
			}
			set session_name	[dict get $merged sso_session]
			set session_cfg		[_ini_section_keys \
				[_config_file_path] "sso-session $session_name"]
			if {[dict size $session_cfg] == 0} {
				throw {AWS PROFILE_INVALID} "profile '$profile' references sso-session '$session_name' but no \[sso-session $session_name\] section exists in the config file"
			}
			foreach k {sso_start_url sso_region} {
				if {![dict exists $session_cfg $k]} {
					throw {AWS PROFILE_INVALID} "\[sso-session $session_name\] is missing $k"
				}
			}
			_sso_creds_common \
				$profile \
				$session_name \
				[dict get $session_cfg sso_start_url] \
				[dict get $session_cfg sso_region] \
				[dict get $merged sso_account_id] \
				[dict get $merged sso_role_name]
		}

		#>>>
		proc _sso_creds_from_legacy {profile merged} { #<<<
			# Legacy form. All four keys on the profile; token cache
			# filename is sha1(sso_start_url).
			foreach k {sso_start_url sso_region sso_account_id sso_role_name} {
				if {![dict exists $merged $k]} {
					throw {AWS PROFILE_INVALID} "profile '$profile' is missing $k"
				}
			}
			_sso_creds_common \
				$profile \
				[dict get $merged sso_start_url] \
				[dict get $merged sso_start_url] \
				[dict get $merged sso_region] \
				[dict get $merged sso_account_id] \
				[dict get $merged sso_role_name]
		}

		#>>>
		proc _sso_creds_common {profile cache_key start_url region account_id role_name} { #<<<
			# Load the on-disk token cache, refresh it if expired and a
			# refresh token is available, then call sso:GetRoleCredentials
			# to mint temporary AWS creds. In-memory cached per-profile
			# until 60s before the creds expire.
			variable _sso_role_creds_cache
			if {
				[info exists _sso_role_creds_cache] &&
				[dict exists $_sso_role_creds_cache $profile] &&
				[clock seconds] < [dict get $_sso_role_creds_cache $profile expires] - 60
			} {
				return [dict get $_sso_role_creds_cache $profile]
			}

			set token_path	[_sso_token_cache_path $cache_key]
			set token		[_sso_load_token $token_path $start_url $cache_key]
			# Refresh if close to expiry and refresh token is present.
			if {
				[clock seconds] >= [dict get $token expires_at] - 60 &&
				[dict exists $token refreshToken] &&
				[dict get $token refreshToken] ne "" &&
				[dict exists $token clientId] &&
				[dict exists $token clientSecret]
			} {
				set token [_sso_refresh_token $region $token $token_path]
			}
			if {[clock seconds] >= [dict get $token expires_at]} {
				throw {AWS SSO_TOKEN_EXPIRED} "SSO access token for profile '$profile' has expired — run 'aws sso login --profile $profile' to refresh"
			}

			set rc [_sso_get_role_credentials \
				$region [dict get $token accessToken] $account_id $role_name]
			# roleCredentials.expiration is epoch milliseconds.
			set expires_sec [expr {[json get $rc expiration] / 1000}]
			set out [dict create \
				access_key	[json get $rc accessKeyId] \
				secret		[json get $rc secretAccessKey] \
				token		[json get $rc sessionToken] \
				expires		$expires_sec \
				source		"sso:$profile" \
			]
			if {![info exists _sso_role_creds_cache]} {
				set _sso_role_creds_cache {}
			}
			dict set _sso_role_creds_cache $profile $out
			return $out
		}

		#>>>
		proc _sso_token_cache_path key { #<<<
			# The CLI / SDKs hash the session name (modern) or sso_start_url
			# (legacy) with SHA-1 and use the lowercase hex digest as the
			# filename under ~/.aws/sso/cache/.
			global env
			if {![info exists env(HOME)]} {
				throw {AWS SSO_NO_HOME} "HOME not set — cannot locate SSO token cache"
			}
			set digest [binary encode hex [tomcrypt::hash sha1 $key]]
			return [file join $env(HOME) .aws/sso/cache $digest.json]
		}

		#>>>
		proc _sso_load_token {path start_url cache_key} { #<<<
			if {![file readable $path]} {
				throw {AWS SSO_NO_TOKEN} "no cached SSO token at $path — run 'aws sso login' first"
			}
			set fh [open $path r]
			try {
				fconfigure $fh -encoding utf-8
				set j [read $fh]
			} finally {
				close $fh
			}
			foreach k {accessToken expiresAt} {
				if {![json exists $j $k]} {
					throw {AWS SSO_TOKEN_INVALID} "SSO token cache at $path is missing $k — re-run 'aws sso login'"
				}
			}
			set out [dict create \
				accessToken		[json get $j accessToken] \
				expires_at		[clock scan [json get $j expiresAt] \
									-timezone :UTC \
									-format {%Y-%m-%dT%H:%M:%SZ}] \
				cache_path		$path \
			]
			foreach k {refreshToken clientId clientSecret region startUrl registrationExpiresAt} {
				if {[json exists $j $k]} {
					dict set out $k [json get $j $k]
				}
			}
			return $out
		}

		#>>>
		proc _sso_refresh_token {region token token_path} { #<<<
			# Call sso-oidc:CreateToken with grant_type=refresh_token,
			# write the new token back to the cache file so the next
			# process can use it too.
			set body [json template {
				{
					"clientId":		"~S:clientId",
					"clientSecret":	"~S:clientSecret",
					"grantType":	"refresh_token",
					"refreshToken":	"~S:refreshToken"
				}
			} $token]
			set url "https://oidc.$region.amazonaws.com/token"
			set ca_bundle [_ca_bundle]
			set extra [expr {$ca_bundle ne "" ? [list -cafile $ca_bundle] : {}}]
			rl_http instvar h POST $url \
				-stats_cx AWS \
				-timeout 10 \
				-headers [list Content-Type application/json Accept application/json] \
				-data $body \
				{*}$extra
			if {[$h code] != 200} {
				throw {AWS SSO_REFRESH_FAILED} "sso-oidc:CreateToken returned [$h code]: [$h body] — run 'aws sso login' to start a new session"
			}
			set resp [$h body]
			set new_token [dict create \
				accessToken		[json get $resp accessToken] \
				expires_at		[expr {[clock seconds] + [json get $resp expiresIn]}] \
				cache_path		$token_path]
			# Preserve registration details we still need for future refreshes.
			foreach k {clientId clientSecret region startUrl registrationExpiresAt} {
				if {[dict exists $token $k]} {
					dict set new_token $k [dict get $token $k]
				}
			}
			# Some servers rotate refreshToken; prefer the new one if present.
			if {[json exists $resp refreshToken]} {
				dict set new_token refreshToken [json get $resp refreshToken]
			} elseif {[dict exists $token refreshToken]} {
				dict set new_token refreshToken [dict get $token refreshToken]
			}
			_sso_write_token_cache $token_path $new_token
			return $new_token
		}

		#>>>
		proc _sso_write_token_cache {path token} { #<<<
			# Write the token back using the CLI's field names and ISO-8601
			# expiresAt so `aws sso login` and other SDKs continue to see it.
			set doc {{}}
			json set doc accessToken [json string [dict get $token accessToken]]
			json set doc expiresAt   [json string \
				[clock format [dict get $token expires_at] -timezone :UTC -format {%Y-%m-%dT%H:%M:%SZ}]]
			foreach fld {refreshToken clientId clientSecret region startUrl registrationExpiresAt} {
				if {[dict exists $token $fld]} {
					json set doc $fld [json string [dict get $token $fld]]
				}
			}
			set dir [file dirname $path]
			if {![file isdirectory $dir]} {file mkdir $dir}
			set tmp $path.tmp[pid]
			set fh [open $tmp {WRONLY CREAT TRUNC} 0600]
			try {
				fconfigure $fh -encoding utf-8 -translation lf
				puts -nonewline $fh $doc
			} finally {
				close $fh
			}
			file rename -force $tmp $path
		}

		#>>>
		proc _sso_get_role_credentials {region access_token account_id role_name} { #<<<
			# sso:GetRoleCredentials is REST-JSON, smithy.api#noAuth. The
			# access token rides as x-amz-sso_bearer_token (the header name
			# SSO expects — lowercased for canonicalization is fine).
			set url		https://portal.sso.$region.amazonaws.com/federation/credentials
			reuri query set url account_id $account_id
			reuri query set url role_name  $role_name
			set ca_bundle	[_ca_bundle]
			set extra		[expr {$ca_bundle ne "" ? [list -cafile $ca_bundle] : {}}]
			rl_http instvar h GET $url \
				-stats_cx	AWS \
				-timeout	10 \
				-headers	[list \
					x-amz-sso_bearer_token	$access_token \
					Accept					application/json] \
				{*}$extra
			if {[$h code] != 200} {
				throw {AWS SSO_GET_ROLE_CREDS_FAILED} "sso:GetRoleCredentials returned [$h code]: [$h body]"
			}
			set resp	[$h body]
			if {![json exists $resp roleCredentials]} {
				throw {AWS SSO_GET_ROLE_CREDS_FAILED} "sso:GetRoleCredentials response missing roleCredentials: [$h body]"
			}
			json extract $resp roleCredentials
		}

		#>>>
		proc _container_creds {} { #<<<
			# Fetch container credentials from either AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
			# (old ECS task role mechanism) or AWS_CONTAINER_CREDENTIALS_FULL_URI
			# (newer, used by EKS Pod Identity Agent). FULL_URI may carry an
			# authorization token in AWS_CONTAINER_AUTHORIZATION_TOKEN or
			# _TOKEN_FILE.
			#
			# Returns a JSON doc with AccessKeyId / SecretAccessKey / Token and
			# an added expires_sec field (epoch seconds parsed from Expiration).
			global env
			variable cached_role_creds

			if {
				[info exists cached_role_creds] &&
				[clock seconds] < [json get $cached_role_creds expires_sec] - 60
			} {
				return $cached_role_creds
			}

			set headers {}
			if {[info exists env(AWS_CONTAINER_CREDENTIALS_RELATIVE_URI)]} {
				set url http://169.254.170.2$env(AWS_CONTAINER_CREDENTIALS_RELATIVE_URI)
			} elseif {[info exists env(AWS_CONTAINER_CREDENTIALS_FULL_URI)]} {
				set url $env(AWS_CONTAINER_CREDENTIALS_FULL_URI)
				if {[info exists env(AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE)]} {
					set fh [open $env(AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE) r]
					try { set tok [string trim [read $fh]] } finally { close $fh }
					lappend headers Authorization $tok
				} elseif {[info exists env(AWS_CONTAINER_AUTHORIZATION_TOKEN)]} {
					lappend headers Authorization $env(AWS_CONTAINER_AUTHORIZATION_TOKEN)
				}
			} else {
				throw {AWS NO_CREDENTIALS} "no container credentials env var set"
			}

			rl_http instvar h GET $url -stats_cx AWS -timeout 2 -headers $headers
			if {[$h code] != 200} {
				throw [list AWS [$h code]] [$h body]
			}
			set cached_role_creds [$h body]
			json set cached_role_creds expires_sec [clock scan [json get $cached_role_creds Expiration] -timezone :UTC -format {%Y-%m-%dT%H:%M:%SZ}]
			return $cached_role_creds
		}

		#>>>
		proc _imds_disabled {} { #<<<
			global env
			if {
				[info exists env(AWS_EC2_METADATA_DISABLED)] &&
				[string tolower $env(AWS_EC2_METADATA_DISABLED)] eq "true"
			} {return 1}
			return 0
		}

		#>>>
		proc _imds_base {} { #<<<
			global env
			if {
				[info exists env(AWS_EC2_METADATA_SERVICE_ENDPOINT)] &&
				$env(AWS_EC2_METADATA_SERVICE_ENDPOINT) ne ""
			} {
				return [string trimright $env(AWS_EC2_METADATA_SERVICE_ENDPOINT) /]/latest
			}
			return http://169.254.169.254/latest
		}

		#>>>
		proc _imds_timeout {} { #<<<
			global env
			if {[info exists env(AWS_METADATA_SERVICE_TIMEOUT)]} {
				return $env(AWS_METADATA_SERVICE_TIMEOUT)
			}
			return 1
		}

		#>>>
		proc _imds_attempts {} { #<<<
			global env
			if {[info exists env(AWS_METADATA_SERVICE_NUM_ATTEMPTS)]} {
				return $env(AWS_METADATA_SERVICE_NUM_ATTEMPTS)
			}
			return 1
		}

		#>>>
		proc _imds_v1_disabled {} { #<<<
			global env
			if {
				[info exists env(AWS_EC2_METADATA_V1_DISABLED)] &&
				[string tolower $env(AWS_EC2_METADATA_V1_DISABLED)] eq "true"
			} {return 1}
			return 0
		}

		#>>>
		proc _imds_token {} { #<<<
			# Fetch or return a cached IMDSv2 session token. TTL 21600s.
			# A return of "" means v2 is unavailable and v1 should be tried
			# (unless _imds_v1_disabled).
			variable _imds_token_cache
			if {
				[info exists _imds_token_cache] &&
				[clock seconds] < [dict get $_imds_token_cache expires]
			} {
				return [dict get $_imds_token_cache token]
			}
			try {
				rl_http instvar h PUT "[_imds_base]/api/token" \
					-stats_cx AWS \
					-timeout [_imds_timeout] \
					-headers [list X-aws-ec2-metadata-token-ttl-seconds 21600]
				if {[$h code] == 200} {
					set token [$h body]
					set _imds_token_cache [dict create \
						token	$token \
						expires	[expr {[clock seconds] + 21000}]]
					return $token
				}
			} on error {} {}
			return ""
		}

		#>>>
		proc _imds_req path { #<<<
			# IMDS fetch with v2 preferred. Tries to obtain a session token;
			# if that fails and v1 is not disabled, retries without the token.
			set base	[_imds_base]
			if {$path eq "/" || $path eq ""} {
				set url $base
			} else {
				set url $base/[string trimleft $path /]
			}
			set token [_imds_token]
			set headers {}
			if {$token ne ""} {
				lappend headers X-aws-ec2-metadata-token $token
			} elseif {[_imds_v1_disabled]} {
				throw {AWS IMDS_UNAVAILABLE} "IMDSv2 token fetch failed and v1 is disabled"
			}
			set attempts [_imds_attempts]
			set last_err {}
			for {set i 0} {$i < $attempts} {incr i} {
				try {
					rl_http instvar h GET $url \
						-stats_cx AWS \
						-timeout [_imds_timeout] \
						-headers $headers
					if {[$h code] == 200} {return [$h body]}
					if {[$h code] == 401 && $token ne ""} {
						# Token expired between fetch and use — drop cache and retry.
						variable _imds_token_cache
						unset -nocomplain _imds_token_cache
						set token [_imds_token]
						set headers [list X-aws-ec2-metadata-token $token]
						continue
					}
					set last_err [list [$h code] [$h body]]
				} on error {msg opts} {
					set last_err [list error $msg]
				}
			}
			throw {AWS IMDS_ERROR} "IMDS request failed ($url): $last_err"
		}

		#>>>
		proc instance_role_creds {} { #<<<
			variable cached_role_creds

			if {
				[info exists cached_role_creds] &&
				[json exists $cached_role_creds expires_sec] &&
				[clock seconds] < [json get $cached_role_creds expires_sec] - 60
			} {
				return $cached_role_creds
			}

			set role				[_imds_req meta-data/iam/security-credentials]
			set cached_role_creds	[_imds_req meta-data/iam/security-credentials/$role]
			json set cached_role_creds expires_sec \
				[clock scan [json get $cached_role_creds Expiration] -timezone :UTC -format {%Y-%m-%dT%H:%M:%SZ}]
			return $cached_role_creds
		}

		#>>>

		proc _metadata_req url { #<<<
			# Legacy compatibility wrapper: unauthenticated GET against the
			# v1 metadata endpoint. Used for ECS metadata URIs (which are
			# not v2-tokened) and some ad-hoc callers.
			rl_http instvar h GET $url -stats_cx AWS -timeout 1
			if {[$h code] != 200} {
				throw [list AWS [$h code]] [$h body]
			}
			$h body
		}

		#>>>
		proc _metadata path { #<<<
			# EC2 / ECS metadata fetch. For EC2 this now uses IMDSv2 when
			# available (falling back to v1 unless disabled). ECS metadata
			# URIs are always unauthenticated.
			global env

			if {[identify] eq "ECS"} {
				foreach v {
					ECS_CONTAINER_METADATA_URI_V4
					ECS_CONTAINER_METADATA_URI
				} {
					if {[info exists env($v)]} {
						set base	$env($v)
						break
					}
				}

				if {![info exists base]} {
					# Try v2
					set base	http://169.254.170.2/v2
				}
				if {$path eq "/"} {
					return [_metadata_req $base]
				}
				return [_metadata_req $base/[string trimleft $path /]]
			}
			# EC2 — use IMDSv2-aware path
			_imds_req $path
		}

		#>>>
		proc ecs_task {} { # Retrieve the ECS task metadata (if running on ECS / Fargate) <<<
			global env

			foreach v {
				ECS_CONTAINER_METADATA_URI_V4
				ECS_CONTAINER_METADATA_URI
			} {
				if {[info exists env($v)]} {
					set base	http://$env($v)
					break
				}
			}

			if {![info exists base]} {
				# Try v2
				set base	http://169.254.170.2/v2
			}

			rl_http instvar h GET $base -stats_cx AWS
			if {[$h code] != 200} {
				throw [list AWS [$h code]] [$h body]
			}
			$h body
		}

		#>>>
	}

	namespace path {
		::parse_args
		::rl_json
		::chantricks
		helpers
	}

	# Region resolution (mirrors AWS CLI):
	#   AWS_REGION → AWS_DEFAULT_REGION → active profile's region= → us-east-1
	variable default_region	[if {[info exists ::env(AWS_REGION)] && $::env(AWS_REGION) ne ""} {
		set ::env(AWS_REGION)
	} elseif {[info exists ::env(AWS_DEFAULT_REGION)] && $::env(AWS_DEFAULT_REGION) ne ""} {
		set ::env(AWS_DEFAULT_REGION)
	} else {
		set _profile_keys	[helpers::_config_profile_keys]
		if {[dict exists $_profile_keys region]} {
			dict get $_profile_keys region
		} else {
			return -level 0 us-east-1
		}
	}]

	proc identify {} { # Attempt to identify the AWS platform: EC2, Lambda, ECS, or none - not on AWS <<<
		_cache identify {
			global env

			if {
				[info exists env(AWS_EXECUTION_ENV)]
			} {
				switch -exact -- $env(AWS_EXECUTION_ENV) {
					AWS_ECS_EC2 -
					AWS_ECS_FARGATE {
						return ECS
					}
				}
			}

			if {
				[info exists env(ECS_CONTAINER_METADATA_URI_V4)] ||
				[info exists env(ECS_CONTAINER_METADATA_URI)]
			} {
				return ECS
			}

			if {[info exists env(LAMBDA_TASK_ROOT)]} {
				return Lambda
			}

			if {
				[file readable /sys/devices/virtual/dmi/id/sys_vendor] &&
				[string trim [readfile /sys/devices/virtual/dmi/id/sys_vendor]] eq "Amazon EC2"
			} {
				return EC2
			}

			return none
		}
	}

	#>>>
	proc availability_zone {}	{json get [instance_identity] availabilityZone}
	proc region {}				{json get [instance_identity] region}
	proc account_id {}			{json get [instance_identity] accountId}
	proc instance_id {}			{json get [instance_identity] instanceId}
	proc image_id {}			{json get [instance_identity] imageId}
	proc instance_type {}		{json get [instance_identity] instanceType}
	proc public_ipv4 {}			{_metadata meta-data/public-ipv4}
	proc local_ipv4 {} { #<<<
		switch -exact -- [identify] {
			ECS {
				json foreach network [json extract [_metadata /] Networks] {
					if {[json get $network NetworkMode] eq "awsvpc"} {
						return [json get $network IPv4Addresses 0]
					}
				}
			}
			none {
				if {![regexp { src ([0-9.]+)} [exec ip route get 10.1.1.1] - myip]} {
					error "Cannot determine local IP"
				}
				set myip
			}
			default {
				_metadata meta-data/local-ipv4
			}
		}
	}

	#>>>

	proc _ei {cache_ns endpointPrefix defaults dnsSuffix region_overrides region} { #<<<
		variable ${cache_ns}::endpoint_cache

		if {![dict exists $endpoint_cache $region]} {
			# TODO: check that the region is valid for this service
			if {[dict exists $region_overrides isRegionalized] && ![dict get $region_overrides isRegionalized]} {
				# Service isn't regionalized, override the region param
				set mregion	[dict get $region_overrides partitionEndpoint]
			} else {
				set mregion	$region
			}
			if {[dict exists $region_overrides defaults]} {
				set defaults	[dict merge $defaults [dict get $region_overrides defaults]]
			}
			if {[dict exists $region_overrides endpoints $mregion]} {
				#puts stderr "merging over ($defaults)\n([dict get $region_overrides endpoints $mregion])"
				set defaults	[dict merge $defaults [dict get $region_overrides endpoints $mregion]]
			}
			set hostname	[string map [list \
				"{service}"		$endpointPrefix \
				"{region}"		$mregion \
				"{dnsSuffix}"	$dnsSuffix \
			] [dict get $defaults hostname]]

			if {[dict exists $defaults sslCommonName]} {
				set sslCommonName	[string map [list \
					"{service}"		$endpointPrefix \
					"{region}"		$mregion \
					"{dnsSuffix}"	$dnsSuffix \
				] [dict get $defaults sslCommonName]]
			} else {
				set sslCommonName	$hostname
			}

			dict set endpoint_cache $region hostname			$hostname
			dict set endpoint_cache $region sslCommonName		$sslCommonName
			dict set endpoint_cache $region protocols			[dict get $defaults protocols]
			dict set endpoint_cache $region signatureVersions	[dict get $defaults signatureVersions]
			dict set endpoint_cache $region disableDoubleEncoding	true
			if {[dict exists $defaults credentialScope]} {
				dict set endpoint_cache $region credentialScope	[dict get $defaults credentialScope]
			} else {
				dict set endpoint_cache $region credentialScope	[list region $mregion]
			}
			dict set endpoint_cache $region region $mregion
		}

		dict get $endpoint_cache $region
	}

	#>>>
	proc _eir region_ignored { #<<<
		set endpoint	[uplevel 2 {endpoint_rules $cxparams}]

		set authscheme	[if {[json exists $endpoint properties authSchemes 0]} {
			json extract $endpoint properties authSchemes 0
		} else {
			set default_region	[json get $endpoint _ region]
			json template {
				{
					"name":						"sigv4",
					"disableDoubleEncoding":	false,
					"signingRegion":			"~S:default_region"
				}
			}
		}]

		if {![json exists $authscheme disableDoubleEncoding]} {
			json set authscheme disableDoubleEncoding false
		}

		set sigver	[json get $authscheme name]
		switch -exact -- $sigver {
			sigv4	{
				set sigver	v4
			}
			sigv4a	{
				set sigver	v4a
			}
		}

		set url		[json get $endpoint url]
		dict create \
			protocols				[list [reuri get $url scheme http]] \
			hostname				[reuri get $url host] \
			url						$url \
			region					[json get $endpoint _ region] \
			credentialScope			[json get $endpoint _ credentialScope] \
			signatureVersions		[list $sigver] \
			disableDoubleEncoding	[json get $authscheme disableDoubleEncoding] \
			signingRegion			[json get $authscheme signingRegion]
	}

	#>>>
	proc _copy2cx args { #<<<
		uplevel 1 [list set cxparams {}]
		uplevel 1 [list foreach {in_param cx_param} $args {
			if {[info exists $in_param]} {
				dict set cxparams $cx_param [set $in_param]
			}
		}]
	}

	#>>>
	proc _builtins args { #<<<
		foreach {v handler} $args {
			switch -exact -- $handler {
				AWS::Region {
					if {![uplevel 1 [list info exists $v]]} {
						uplevel 1 [list set $v $::aws::default_region]
					}
				}
				AWS::UseFIPS {
					if {![uplevel 1 [list info exists $v]]} {
						uplevel 1 [list set $v [expr {
							[helpers::_config_bool USE_FIPS_ENDPOINT 0] ? "true" : "false"
						}]]
					}
				}
				AWS::UseDualStack {
					if {![uplevel 1 [list info exists $v]]} {
						uplevel 1 [list set $v [expr {
							[helpers::_config_bool USE_DUALSTACK_ENDPOINT 0] ? "true" : "false"
						}]]
					}
				}
				AWS::STS::UseGlobalEndpoint {
					# CLI's sts_regional_endpoints=legacy means "use the
					# global endpoint" — the endpoint rule expects the
					# inverted sense: UseGlobalEndpoint=true ⇒ legacy.
					if {![uplevel 1 [list info exists $v]]} {
						set raw [expr {
							[info exists ::env(AWS_STS_REGIONAL_ENDPOINTS)]
							? $::env(AWS_STS_REGIONAL_ENDPOINTS)
							: [helpers::_profile_value sts_regional_endpoints]
						}]
						uplevel 1 [list set $v [expr {
							[string tolower $raw] eq "legacy" ? "true" : "false"
						}]]
					}
				}
				default {
					#log warning "Built-in not implemented: \"$handler\""
				}
			}
		}
	}

	#>>>
	proc _auto_idempotency_token var { #<<<
		# Auto-populate an idempotency-token member. Called from generated
		# op code before _service_req when the input shape has a member with
		# idempotencyToken:true: if the caller didn't supply a value, we
		# insert a freshly generated UUIDv4 so that a retry of the request
		# (either by this SDK or an application-level retry) is deduped by
		# the service. No-op if the caller provided their own token.
		upvar 1 $var v
		if {![info exists v]} {
			set v	[::aws::helpers::_uuid4]
		}
	}

	#>>>
	proc _apply_tx {kind var args} { #<<<
		# Per-shape body-value transforms applied before json template substitution.
		# compile_input emits an `if {[info exists X]} {set _tx_X [_tx_FOO $X]}` line
		# for each member that needs pre-template conversion; the template then
		# references `~{S,J,N}:_tx_X` rather than the raw arg.
		#
		# Called at op-proc start: if $var is set, computes the transformed
		# value into _tx_$var in the caller's scope. Template substitutions
		# reference ~{S,J,N}:_tx_$var so missing args still resolve to null.
		# The rewrite kind takes an extra spec argument that drives a walk
		# over the user-supplied JSON fragment.
		upvar 1 $var src _tx_$var dst
		if {![info exists src]} return
		set dst [switch -exact -- $kind {
			blob		{_tx_blob $src}
			float		{_tx_float $src}
			ts_epoch	{_tx_ts_epoch $src}
			ts_iso		{_tx_ts_iso $src}
			ts_rfc822	{_tx_ts_rfc822 $src}
			rewrite		{_tx_rewrite $src [lindex $args 0]}
			default		{error "Unhandled transform kind \"$kind\""}
		}]
	}

	#>>>
	proc _tx_rewrite {val spec} { #<<<
		# Walk a user-supplied JSON fragment per the rewriter spec, producing
		# a transformed JSON fragment suitable for ~J:. Spec forms:
		#   identity
		#   blob                          base64-encode a JSON string
		#   float                         wrap NaN/Infinity as JSON strings
		#   {ts iso8601|unixTimestamp|rfc822}
		#   {struct {ckey loc subspec ...}}   object: rename keys, recurse
		#   {list subspec}                array: recurse into each element
		#   {map value_subspec}           object used as a map: recurse values
		# All accepts and all returns are valid JSON fragments.
		if {$spec eq "" || $spec eq "identity"} {return $val}
		switch -exact -- [lindex $spec 0] {
			blob {
				# val is a JSON string; decode, base64-encode, re-quote.
				json string [binary encode base64 [json get $val]]
			}
			float {
				set v [json get $val]
				if {$v in {NaN Infinity -Infinity}} {json string $v} else {set val}
			}
			ts {
				set fmt		[lindex $spec 1]
				set epoch	[_tx_ts_parse [json get $val]]
				switch $fmt {
					unixTimestamp	{json number $epoch}
					rfc822			{json string [clock format $epoch -format {%a, %d %b %Y %H:%M:%S GMT} -timezone :UTC]}
					default			{json string [clock format $epoch -format {%Y-%m-%dT%H:%M:%SZ} -timezone :UTC]}
				}
			}
			struct {
				lassign $spec - members
				# Build a key→{loc subspec} lookup for fast rename/recurse.
				set by_key {}
				foreach {ck lk sub} $members {
					dict set by_key $ck [list $lk $sub]
				}
				set out {{}}
				json foreach {k v} $val {
					if {![dict exists $by_key $k]} continue
					lassign [dict get $by_key $k] loc sub
					json set out $loc [_tx_rewrite [json extract $val $k] $sub]
				}
				set out
			}
			list {
				lassign $spec - sub
				set out {[]}
				set i -1
				json foreach e $val {
					incr i
					json set out end+1 [_tx_rewrite [json extract $val $i] $sub]
				}
				set out
			}
			map {
				lassign $spec - value_sub
				set out {{}}
				json foreach {k v} $val {
					json set out $k [_tx_rewrite [json extract $val $k] $value_sub]
				}
				set out
			}
			default {
				error "Unhandled rewrite spec: [list $spec]"
			}
		}
	}

	#>>>
	proc _tx_blob val { #<<<
		# JSON body blobs are base64 strings.
		binary encode base64 $val
	}

	#>>>
	proc _tx_float val { #<<<
		# AWS JSON protocols serialize non-finite floats as strings.
		if {$val in {NaN Infinity -Infinity}} {
			json string $val
		} else {
			set val
		}
	}

	#>>>
	proc _tx_ts_epoch val { #<<<
		# Convert the user's value (ISO 8601 or epoch integer) to an epoch
		# integer suitable for a JSON number. Used for json / rest-json where
		# the default timestampFormat is unixTimestamp.
		_tx_ts_parse $val
	}

	#>>>
	proc _tx_ts_iso val { #<<<
		clock format [_tx_ts_parse $val] -format {%Y-%m-%dT%H:%M:%SZ} -timezone :UTC
	}

	#>>>
	proc _tx_ts_rfc822 val { #<<<
		clock format [_tx_ts_parse $val] -format {%a, %d %b %Y %H:%M:%S GMT} -timezone :UTC
	}

	#>>>
	proc _tx_ts_parse val { #<<<
		# Accept an epoch integer or an ISO 8601 string, return epoch seconds.
		if {[string is integer -strict $val]} {return $val}
		clock scan $val -format {%Y-%m-%dT%H:%M:%SZ} -timezone :UTC
	}

	#>>>
	proc _flatten_query_param {queryvar prefix value spec} { #<<<
		# Serialize $value into $queryvar as query-string pairs, honouring the
		# shape spec produced by aws::build::compile_query_spec. Spec forms:
		#   ""                              scalar
		#   {list <memberName> <flat> <subspec>}
		#   {struct {memberLoc subspec ...}}
		#   {map <flat> <key_name> <key_subspec> <val_name> <val_subspec>}
		#
		# Values are always native Tcl: scalars are strings, list shapes are Tcl
		# lists, structure and map shapes are Tcl dicts.
		upvar 1 $queryvar query
		if {$spec eq ""} {
			lappend query $prefix $value
			return
		}
		if {$spec eq "bool"} {
			# AWS query/ec2 wire format: true / false (not 1 / 0).
			lappend query $prefix [expr {$value ? "true" : "false"}]
			return
		}
		if {$spec eq "blob"} {
			# Blobs in body contexts are base64 encoded.
			lappend query $prefix [binary encode base64 $value]
			return
		}
		switch -exact -- [lindex $spec 0] {
			timestamp {
				# Accept ISO 8601 strings or integer seconds. Emit in the
				# format the shape declared.
				lassign $spec - fmt
				set epoch	[if {[string is integer -strict $value]} {
					set value
				} else {
					clock scan $value
				}]
				lappend query $prefix [switch -exact -- $fmt {
					unixTimestamp	{set epoch}
					rfc822			{clock format $epoch -format {%a, %d %b %Y %H:%M:%S GMT} -timezone :UTC}
					default			{clock format $epoch -format {%Y-%m-%dT%H:%M:%SZ} -timezone :UTC}
				}]
			}
			list {
				lassign $spec - member_name flat subspec
				set base	[expr {$flat ? $prefix : "$prefix.$member_name"}]
				set i	0
				foreach item $value {
					incr i
					_flatten_query_param query "$base.$i" $item $subspec
				}
			}
			struct {
				lassign $spec - members
				# members is a list of {data_key serialized subspec} triples.
				set by_key	{}
				foreach {k loc sub} $members {
					dict set by_key $k [list $loc $sub]
				}
				dict for {k v} $value {
					if {![dict exists $by_key $k]} continue
					lassign [dict get $by_key $k] loc sub
					_flatten_query_param query "$prefix.$loc" $v $sub
				}
			}
			map {
				lassign $spec - flat key_name key_spec val_name val_spec
				set base	[expr {$flat ? $prefix : "$prefix.entry"}]
				set i		0
				dict for {k v} $value {
					incr i
					_flatten_query_param query "$base.$i.$key_name" $k $key_spec
					_flatten_query_param query "$base.$i.$val_name" $v $val_spec
				}
			}
			default {
				error "Unhandled query spec: [list $spec]"
			}
		}
	}

	#>>>
	proc _service_req args { #<<<
		parse_args $args {
			-b			{-default {} -name payload}
			-c			{-default application/x-amz-json-1.1 -name content_type}
			-e			{-default 200 -name expected_status}
			-h			{-default {} -name headers}
			-hm			{-default {} -name header_map}
			-m			{-default POST -name method}
			-o			{-default {} -name out_headers_map}
			-p			{-default / -name path}
			-q			{-default {} -name query_map}
			-R			{-default {} -name response}
			-r			{-default {} -name region}
			-sm			{-default {} -name status_map}
			-s			{-required -name signingName}
			-t			{-default {} -name template}
			-u			{-default {} -name uri_map}
			-w			{-default {} -name resultWrapper}
			-x			{-default {} -name xml_input}
			-handleresp	{}
			-payload	{-alias -name resp_payload}
		}

		if {$region eq ""} {
			set region	$::aws::default_region
		}

		_debug {
			if {$template ne ""} {set template_js $template}
			log debug "AWS _service_req" {
				{
					"payload":			"~S:payload",
					"content_type":		"~S:content_type",
					"expected_status":	"~N:expected_status",
					"headers":			"~S:headers",
					"header_map":		"~S:header_map",
					"path":				"~S:path",
					"query_map":		"~S:query_map",
					"response":			"~S:response",
					"region":			"~S:region",
					"status_map":		"~S:status_map",
					"signingName":		"~S:signingName",
					"template":			"~J:template_js",
					"uri_map":			"~S:uri_map",
					"resultWrapper":	"~S:resultWrapper",
					"xml_input":		"~S:xml_input"
				}
			}
		}


		uplevel 1 {unset args}
		#set upvars	[lmap v [uplevel 1 {info vars}] {if {$v in {ei args}} continue else {set v}}]
		set upvars	[uplevel 1 {info vars}]
		#puts stderr "upvars: $upvars"
		set service_ns	[uplevel 1 {
			if {![info exists ei]} {variable ei}
			variable protocol
			variable apiVersion
			namespace current
		}]

		upvar 1 ei ei  protocol protocol  response_headers response_headers  cxparams cxparams  {*}[concat {*}[lmap uv $upvars {list $uv _a_$uv}]]
		if {[info exists _a_params]} {
			dict for {k v} $_a_params {
				_debug {log notice "unpacking params($k) -> ($v)"}
				set _a_$k $v
			}
		}

		set endpoint_info	[{*}$ei $region]
		helpers::_apply_endpoint_override endpoint_info [namespace tail $service_ns]
		_debug {log notice "endpoint_info:\n\t[join [lmap {k v} $endpoint_info {format {%20s: %s} $k $v}] \n\t]"}
		set uri_map_out	{}
		foreach {pat arg} $uri_map {
			set rep	[if {[info exists _a_$arg]} {
				set _a_$arg
			}]
			set repe	[reuri encode path $rep]
			#lappend uri_map_out	"{$pat}" $repe "{$pat+}" [string map {%2F /} $repe]
			lappend uri_map_out	"{$pat}" $repe "{$pat+}" [reuri::path join {*}[reuri::path get [string map {+ %2B} $rep]]]
		}
		#puts stderr "uri_map_out: ($uri_map_out)"

		foreach {header arg} $header_map {
			if {[info exists _a_$arg]} {
				if {[string index $header end] eq "*"} {
					set header_pref	[string range $header 0 end-1]
					json foreach {k v} [set _a_$arg] {
						lappend headers $header_pref$k $v
					}
				} else {
					lappend headers $header [set _a_$arg]
				}
			}
		}

		set query	{}
		# query_map is a flat list of triples {prefix argname spec}, where spec
		# is empty for scalars or {list <name> <flat> <subspec>} /
		# {struct <members>} for shapes that need flattening (ec2 / query).
		foreach {name arg spec} $query_map {
			if {[info exists _a_$arg]} {
				_flatten_query_param query $name [set _a_$arg] $spec
			}
		}
		#puts stderr "query_map ($query_map), query: ($query)"

		if {$protocol in {query ec2} && [info exists ${service_ns}::apiVersion]} {
			# Inject the Version param
			lappend query Version [set ${service_ns}::apiVersion]
		}

		#puts stderr "payload: ($payload)"
		if {$content_type eq "application/x-www-form-urlencoded; charset=utf-8"} {
			set body	[join [lmap {k v} $query {
				format %s=%s [reuri encode query $k] [reuri encode query $v]
			}] &]
			set query	{}
		} elseif {$payload ne ""} {
			#puts "exists: [info exists _a_$payload]"
			if {[info exists _a_$payload]} {
				if {$xml_input in {{} {Body {} {}}}} {
					set body	[set _a_$payload]
				} else {
					set rest	[lassign $xml_input rootelem xmlns]
					set doc	[dom createDocument $rootelem]
					try {
						set src		[set _a_$payload]
						set root	[$doc documentElement]
						_xml_add_input_nodes $root $rest $src
						if {$xmlns ne ""} {
							set doc	[$root setAttribute xmlns $xmlns]
						}
					} on ok {} {
						set body	[encoding convertto utf-8 [$root asXML]]
					} finally {
						$doc delete
					}
				}
			} else {
				set body	{}
			}
			#puts stderr "body: ($body)"
		} elseif {$template ne {}} {
			set bodydoc	[uplevel 1 [list json template $template]]
			# Strip null object keys and array elements <<<
			set paths	{{}}
			while {[llength $paths]} {
				set paths	[lassign $paths thispath]
				switch -exact -- [json type $bodydoc {*}$thispath] {
					object {
						json foreach {k v} [json extract $bodydoc {*}$thispath] {
							if {[json exists $v]} {
								lappend paths	[list {*}$thispath $k]
							} else {
								json unset bodydoc {*}$thispath $k
							}
						}
					}
					array {
						for {set i [json length [json extract $bodydoc {*}$thispath]]} {$i >= 0} {incr i -1} {
							if {[json exists $bodydoc {*}$thispath $i]} {
								lappend paths	[list {*}$thispath $i]
							} else {
								json unset bodydoc {*}$thispath $i
							}
						}
					}
				}
			}
			# Strip null object keys and array elements >>>
			if {0 && [json length $bodydoc] == 0} {
				set body	""
				set content_type	""
			} else {
				set body	[encoding convertto utf-8 $bodydoc]
			}
		} else {
			set body	{}
			set content_type	""
		}

		#set scheme	[lindex [dict get $endpoint_info protocols] end]
		set scheme	[lindex [dict get $endpoint_info protocols] 0]
		if {[string tolower $scheme] eq "https" && [dict exists $endpoint_info sslCommonName]} {
			set hostname	[dict get $endpoint_info sslCommonName]
		} else {
			set hostname	[dict get $endpoint_info hostname]
		}

		try {
			_debug {log notice "Requesting $method $hostname, path: ($path)($uri_map_out) -> ([string map $uri_map_out $path]), query: ($query), headers: ($headers), body:\n$body"}
			_aws_req $method $hostname [string map $uri_map_out $path] \
				-params						$query \
				-sig_service				$signingName \
				-scheme						$scheme \
				-region						[dict get $endpoint_info region] \
				-credential_scope			[dict get $endpoint_info credentialScope region] \
				-disable_double_encoding	[if {[dict exists $endpoint_info disableDoubleEncoding]} {dict get $endpoint_info disableDoubleEncoding} else {return -level 0 true}] \
				-signing_region				[if {[dict exists $endpoint_info signingRegion]} {dict get $endpoint_info signingRegion} else {dict get $endpoint_info region}] \
				-version					[lindex [dict get $endpoint_info signatureVersions] end] \
				-body						$body \
				-content_type				$content_type \
				-headers					$headers \
				-expecting_status			$expected_status \
				-response_headers			response_headers \
				-status						status \
				{*}[if {[info exists _a_timeout]             && $_a_timeout             ne ""} {list -timeout             $_a_timeout}] \
				{*}[if {[info exists _a_connect_timeout]     && $_a_connect_timeout     ne ""} {list -connect_timeout     $_a_connect_timeout}] \
				{*}[if {[info exists _a_read_timeout]        && $_a_read_timeout        ne ""} {list -read_timeout        $_a_read_timeout}] \
				{*}[if {[info exists _a_max_keepalive_age]   && $_a_max_keepalive_age   ne ""} {list -max_keepalive_age   $_a_max_keepalive_age}] \
				{*}[if {[info exists _a_max_keepalive_count] && $_a_max_keepalive_count ne ""} {list -max_keepalive_count $_a_max_keepalive_count}]
		} on ok body {
			if {[info exists handleresp]} {
				resp_cx instvar cx -status $status -headers $response_headers -body $body
				return [{*}$handleresp -cx $cx -payload resp_payload]
			}
			if {$status_map ne ""} {
				set _a_$status_map	$status
			}
			#puts stderr "response_headers:\n\t[join [lmap {k v} $response_headers {format {%20s: %s} $k [join $v {, }]}] \n\t]"
			foreach {header var} [list x-amzn-requestid -requestid {*}$out_headers_map] {
				#puts stderr "checking for ($header) in [dict keys $response_headers]"
				if {[string index $header end] eq "*"} {
					set tmp	{{}}
					foreach {h v} $response_headers {
						if {![string match $header $h]} continue
						set tail	[string range $h [string length $header]-1 end]
						if {[json exists $tmp $tail]} {
							# Already exists: multiple instances of this header, promote result to an array and
							# append
							if {[json type $tmp $tail] ne "array"} {
								json set tmp $tail "\[[json extract $tmp $tail]\]"
							}
							json set tmp $tail end+1 [json string $v]
						} else {
							json set tmp $tail [json string $v]
						}
					}
					if {[json length $tmp] > 0} {
						# Only set the output var if matching headers were found
						set _a_$var	$tmp
					}
					unset tmp
				} else {
					if {![dict exists $response_headers $header]} continue
					set _a_$var [lindex [dict get $response_headers $header] 0]
				}
			}
			try {
				if {$protocol in {query ec2 rest-xml} && $body ne ""} {
					# TODO: check content-type xml?
					package require tdom
					# Strip the xmlns
					set doc [dom parse -ignorexmlns $body]
					#puts stderr "converting XML response with (>$resultWrapper< [dict get [set ${service_ns}::responses] $response]):\n[$doc asXML]"
					try {
						set root	[$doc documentElement]
						$root removeAttribute xmlns
						set body	[$root asXML]
					} finally {
						$doc delete
					}

					if {![dict exists [set ${service_ns}::responses] $response]} {
						error "No response handler defined for ($response):\n\t[join [lmap {k v} [set ${service_ns}::responses] {format {%20s: %s} $k $v}] \n\t]"
					}
					#puts "calling _resp_xml with [list $resultWrapper {*}[dict get [set ${service_ns}::responses] $response]]\n$body"
					_resp_xml $resultWrapper {*}[dict get [set ${service_ns}::responses] $response] $body
				} else {
					set body
				}
			} on ok body {
				if {
					[info exists ::tcl_interactive] &&
					$::tcl_interactive
				} {
					# Pretty print the json response if we're run interactively
					catch {
						set body	[json pretty $body]
					}
				}
				set body
			}
		}
	}

	#>>>
	gc_class create resp_cx { #<<<
		variable {*}{
			status
			body
			headers
			doc
		}
		constructor args { #<<<
			namespace path [list {*}[namespace path] {*}{
				::parse_args
				::rl_json
				::aws::helpers
			}]
			parse_args $args {
				-status		{-required}
				-body		{-required}
				-headers	{-required}
			}

			if {[self next] ne {}} next
		}

		#>>>
		destructor { #<<<
			if {[info exists doc]} {
				$doc delete
				unset doc
			}
			if {[self next] ne ""} next
		}

		#>>>
		foreach m {status body headers} {method $m {} [list set $m]}
		method header args { #<<<
			parse_args $args {
				op		{-required -enum {get exists}}
				name	{-required}
			}

			set name	[string tolower $name]
			switch -exact -- $op {
				exists	{dict exists $headers $name}
				get		{lindex [dict get $headers $name] 0}
			}
		}

		#>>>
		method xmlroot {} { #<<<
			if {![info exists doc]} {
				set doc	[dom parse -ignorexmlns $body]
			}
			$doc documentElement
		}

		#>>>
	}

	#>>>
	proc _build_resp_frag args { #<<<
		parse_args $args {
			-cx					{-required}
			-def				{-required}
			-shape				{-required}
			-cxnode				{}
			-locationname		{}
			-header				{}
			-headers			{}
			-val				{}
			-suppress_fields	{-default {}}
			-toplevel			{-boolean}
		}

		switch -exact -- [json get $shape type] {
			boolean - integer - long - timestamp - string {
				if {![info exists val]} {
					if {[info exists cxnode]} {
						set val	[string trim [domNode $cxnode asText]]
					} elseif {[info exists header]} {
						if {![$cx header exists $header]} {
							return null
						}
						set val	[string trim [$cx header get $header]]
					} else {
						error "No source location for response fragment"
					}
				}
				return [switch -exact -- [json get $shape type] {
					boolean			{json boolean $val}
					integer - long	{json number $val}
					default			{json string $val}
				}]
			}
		}

		_debug {log debug "_build_resp_frag [json get $shape type], suppress_fields: ($suppress_fields):\n[if {[info exists cxnode] && $cxnode ne {}} {domNode $cxnode asXML} {return -level 0 none}]\nshape: [json pretty $shape]"}

		switch -exact -- [json get $shape type] {
			blob { #<<<
				set val
				#>>>
			}
			boolean { #<<<
				_debug { #<<<
					json unset shape type
					if {[json length $shape]} {puts stderr "Unhandled specification in boolean shape: [json pretty $shape]"}
				}
				#>>>
				json boolean $val
				#>>>
			}
			integer - long { #<<<
				_debug { #<<<
					json unset shape type
					if {[json length $shape]} {puts stderr "Unhandled specification in long shape: [json pretty $shape]"}
				}
				#>>>
				json number $val
				#>>>
			}
			timestamp { #<<<
				_debug { #<<<
					json unset shape type
					# TODO: handle timestampFormat {iso8601 rfc822}
					json unset shape timestampFormat
					if {[json length $shape]} {puts stderr "Unhandled specification in timestamp shape: [json pretty $shape]"}
				}
				#>>>
				json string $val
				#>>>
			}
			string { #<<<
				_debug { #<<<
					json unset shape type
					json unset shape enum
					json unset shape pattern
					json unset shape sensitive
					json unset shape min
					json unset shape max
					json unset shape documentation
					if {[json length $shape]} {puts stderr "Unhandled keys in string shape: [json keys $shape]"}
				}
				#>>>
				json string $val
				#>>>
			}
			list { #<<<
				set membershapename	[json get $shape member shape]
				set location		[json get -default {} $shape member location]
				# For non-flattened lists the element tag defaults to "member"
				# (the AWS query protocol convention); flattened lists inline
				# each element under the parent's locationName.
				set flat			[json get -default false $shape flattened]
				if {[json exists $shape member locationName]} {
					set name	[json get $shape member locationName]
				} elseif {$flat && [info exists locationname]} {
					set name	$locationname
				} else {
					set name	member
				}
				set membershape		[json extract $def shapes $membershapename]
				_debug { #<<<
					json unset shape type
					json unset shape member shape
					json unset shape member locationName
					json unset shape flattened
					json unset shape documentation
					if {[json length $shape member] == 0} {json unset shape member}
					if {[json length $shape]} {puts stderr "Unhandled specification in list shape: [json pretty $shape]"}
				}
				#>>>
				set res {[]}
				foreach node [domNode $cxnode selectNodes $name] {
					json set res end+1 [_build_resp_frag \
						-cx		$cx \
						-def	$def \
						-shape	$membershape \
						-cxnode	$node \
					]
				}
				set res
				#>>>
			}
			structure { #<<<
				set res	{{}}
				json foreach {member info} [json extract $shape members] {
					if {$member in $suppress_fields} continue
					set membershape		[json extract $def shapes [json get $info shape]]
					set location		[json get -default {} $info location]
					set locationName	[json get -default $member $info locationName]

					set cxargs			{}
					switch -exact -- $location {
						{} {
							if {![info exists cxnode]} {
								set cxnode	[$cx xmlroot]
							}
							if {[json get -default false $info xmlAttribute]} {
								lappend mlist	[list $member]	[list -val [domNode $cxnode getAttribute $locationName]]
							} else {
								if {![json get -default false $def shapes [json get $info shape] flattened]} {
									set node		[domNode $cxnode selectNodes "$locationName\[1\]"]
									if {$node eq "" && $toplevel} {
										set node	[domNode $cxnode selectNodes "/$locationName\[1\]"]
									}
								} else {
									set node	$cxnode
								}
								if {$node eq ""} continue
								lappend cxargs	-cxnode $node -locationname $locationName
							}
						}

						header	{lappend cxargs -header $locationName}
						headers	{lappend cxargs -headers $locationName}

						querystring - uri - default {
							error "Unexpected location for structure member \"$member\": \"$location\""
						}
					}

					set val	[_build_resp_frag \
						-cx		$cx \
						-def	$def \
						-shape	[json extract $def shapes [json get $info shape]] \
						{*}$cxargs \
					]

					if {[json exists $val]} {
						json set res $member $val
					}

					_debug { #<<<
						json unset info shape
						json unset info documentation
						json unset info contextParam
						json unset info location
						json unset info locationName
						#json unset info flattened			;# TODO: implement
						#json unset info eventpayload		;# TODO: implement
						#json unset info hostLabel			;# TODO: implement
						json unset info deprecated
						json unset info xmlNamespace
						json unset info streaming
						if {[json length $info]} {puts stderr "Unhandled keys in structure member: [json keys $info]"}
					}
					#>>>
				}

				_debug { #<<<
					json unset shape type
					json unset shape required
					json unset shape members
					json unset shape exception
					json unset shape payload
					json unset shape documentation
					json unset shape event
					json unset shape xmlNamespace
					json unset shape locationName
					json unset shape eventstream
					if {[json length $shape]} {puts stderr "Unhandled keys in structure shape: [json keys $shape]"}
				}
				#>>>

				set res
				#>>>
			}
			map { #<<<
				set keyshape	[json extract $def shapes [json get $shape key shape]]
				set valshape	[json extract $def shapes [json get $shape value shape]]

				set res	{{}}
				if {[info exists headers]} {
					set prefix		[string tolower $headers]
					set prefix_len	[string length $prefix]
					foreach {k v} [$cx headers] {
						if {[string range $k 0 $prefix_len-1] eq $prefix} {

							# Only strings are supported as json keys, so ignore $keyshape here (the only extant use resolves to a string anyway)
							set key		[string range $k $prefix_len end]

							set val		[_build_resp_frag \
								-cx		$cx \
								-def	$def \
								-shape	$valshape \
								-val	[lindex [dict get [$cx headers] $k] 0] \
							]

							json set res $key $val
						}
					}
				} else {
					error "Location for map not implemented"
				}

				_debug { #<<<
					json unset shape type
					json unset shape key shape
					json unset shape value shape
					if {[json length $shape key] == 0} {json unset shape key}
					if {[json length $shape value] == 0} {json unset shape value}
					if {[json length $shape]} {puts stderr "Unhandled keys in map shape: [json keys $shape]"}
				}
				#>>>

				set res
				#>>>
			}
			default {error "unknown outshape type: ([json get $outshape type])"}
		}
	}

	#>>>
	proc _handle_xml_resp {def op args} { #<<<
		parse_args $args {
			-cx			{-required}
			-payload	{-alias}
		}

		set output		[json extract $def operations $op output]
		set outshape	[json extract $def shapes [json get $def operations $op output shape]]

		#_debug {
		#	if {[json length $output] > 1} {
		#		json unset output shape
		#		log debug "keys other than shape defined in output: [json pretty $output]"
		#	}
		#}
		#_debug {log debug "Output shape:\n[json pretty $outshape]"}
		#_debug {log debug "status: [$cx status]"}
		#_debug {log debug "headers:\n\t[join [lmap {k v} [$cx headers] {
		#	format {%30s: %s} $k $v
		#}] \n\t]"}
		#_debug {log debug "body:\n[$cx body]"}

		try {
			set cxargs	{}

			if {[json exists $outshape payload]} {
				set suppress_fields	[list [json get $outshape payload]]
				set payload	[_build_resp_frag \
					-cx		$cx \
					-def	$def \
					-shape	[json extract $def shapes [json get $outshape members [json get $outshape payload] shape]] \
					-val	[$cx body] \
				]
			} else {
				if {[dict exists [$cx headers] content-type] && [lindex [dict get [$cx headers] content-type] 0] in {text/xml application/xml}} {
					set doc		[dom parse -ignorexmlns [$cx body]]
					_debug {log debug "XML:\n[domDoc $doc asXML]"}
					lappend cxargs	-cxnode [$doc documentElement]
				}
				set suppress_fields	{}
			}

			_build_resp_frag -toplevel \
				-cx					$cx \
				-def				$def \
				-shape				$outshape \
				-suppress_fields	$suppress_fields \
				{*}$cxargs
		} finally {
			if {[info exists doc]} {
				$doc delete
			}
		}
	}

	#>>>
	proc _xml_add_elem {parent elem src children} { #<<<
		switch -exact -- [json type $src] {
			string - number {
				set val	[json get $src]
			}

			boolean {
				if {[json get $src]} {set val 1} else {set val 0}
			}

			null {
				return
			}
		}

		set doc	[$parent ownerDocument]
		set new	[$doc createElement $elem]
		if {[info exists val]} {
			$new appendChild [$doc createTextNode $val]
		}
		$parent appendChild $new

		_xml_add_input_nodes $new $children $src

		set new
	}

	#>>>
	proc _xml_add_input_nodes {node steps data} { #<<<
		#puts "_xml_add_input_nodes steps: ($steps), data: [json pretty $data]"
		foreach step $steps {
			lassign $step elem children

			switch -glob -- $elem {
				"\\**" - =* - %* {
					set elemname	[string range $elem 1 end]
				}
				default {
					set elemname	$elem
				}
			}

			switch -glob -- $elem {
				"\\**" { # list
					json foreach e $data {
						_xml_add_elem $node $elemname $e $children
					}
				}
				=* { # map
					lassign $children keyname valuename children
					json foreach {k v} $data {
						set doc		[$node ownerDocument]
						set entry	[$doc createElement $elemname]
						$node appendChild $entry
						_xml_add_elem $entry $keyname [json string $k]
						_xml_add_elem $entry $valuename $v $children
					}
				}
				%* { # structure
					error "structure not implemented yet, children: $children"
				}
				default { # leaf
					_xml_add_elem $node $elemname [json extract $data $elemname] $children
				}
			}
		}
	}

	#>>>
	proc _text_from_1_node nodes { #<<<
		if {[llength $nodes] != 1} {
			error "[llength $nodes] returned where 1 expected"
		}
		[lindex $nodes 0] text
	}

	#>>>
	proc _compile_type {type node xpath rest} { #<<<
		#puts stderr "_compile_type, type: ($type), node: ([$node asXML -indent none]), xpath: ($xpath), rest: ($rest)"
		if {$xpath eq {}} {
			set matches	[list $node]
		} else {
			set matches	[$node selectNodes $xpath]
			if {[llength $matches] == 0} {
				throw null "Found nothing for $xpath"
			}
		}
		# Atomic types: make sure there is exactly 1 match
		switch -exact -- $type {
			string - number - boolean - blob - timestamp {
				if {[llength $matches] != 1} {
					error "[llength $matches] returned for ($xpath) where 1 expected on:\n[$node asXML]"
				}
				set val_text	[_text_from_1_node $matches]
			}
		}
		switch -exact -- $type {
			string		{json string  $val_text}
			number		{json number  $val_text}
			boolean		{json boolean $val_text}
			blob		{json string  $val_text}
			timestamp	{json string  $val_text}
			list {
				parse_args $rest {
					subfetchlist	{-required}
					subtemplate		{-required}
				}
				set val	{[]}
				foreach match $matches {
					# TODO: Handle attribs?
					json set val end+1 [_assemble_json $match $subfetchlist $subtemplate]
				}
				set val
			}
			map {
				parse_args $rest {
					keyname			{-required}
					subfetchlist	{-required}
					subtemplate		{-required}
				}
				set val	{{}}
				foreach match $matches {
					set keytext	[_text_from_1_node [$match selectNodes $keyname]]
					json set val $keytext [_assemble_json $match $subfetchlist $subtemplate]
				}
				set val
			}
			structure {
				parse_args $rest {
					subfetchlist	{-required}
					subtemplate		{-required}
				}
				if {[llength $matches] != 1} {
					error "compiling structure, expected 1 match for ($xpath), got: [llength $matches]"
				}
				_assemble_json [lindex $match 0] $subfetchlist $subtemplate
			}
			default {
				error "Unexpected type \"$type\""
			}
		}
	}

	#>>>
	proc _assemble_json {cxnode fetchlist template} { #<<<
		set d	{}
		foreach e $fetchlist {
			set rest	[lassign $e tag type xpath]
			set is_array [string is upper $type]
			set type	[dict get {
				s	string
				n	number
				b	boolean
				x	blob
				l	list
				t	structure
				m	map
				c	timestamp
			} [string tolower $type]]
			try {
				dict set d $tag [_compile_type $type $cxnode $xpath $rest]
			} trap null {} {}
		}
		#puts stderr "d: ($d), into $template"
		json template $template $d
	}

	#>>>
	proc _resp_xml {resultWrapper fetchlist template xml} { #<<<
		package require tdom
		set doc	[dom parse -ignorexmlns $xml]
		try {
			set root	[$doc documentElement]
			if {$resultWrapper eq {}} {
				set result	$root
			} else {
				set result	[lindex [$root selectNodes $resultWrapper] 0]
			}
			_assemble_json $result $fetchlist $template
		} finally {
			$doc delete
		}
	}

	#>>>
	proc _load {{custom_maps {}}} { #<<<
		set file	[uplevel 1 {info script}]
		set h		[open $file rb]
		set bytes	[try {read $h} finally {close $h}]
		set eof		[string first \x1A $bytes]
		set reconstructed	[_reconstruct $custom_maps [encoding convertfrom utf-8 [zlib gunzip [string range $bytes $eof+1 end]]]]
		#puts stderr "reconstructed:\n$reconstructed"
		eval $reconstructed
	}

	#>>>
	proc _load_br {{custom_maps {}}} { #<<<
		package require brotli
		set file	[uplevel 1 {info script}]
		set h		[open $file rb]
		set bytes	[try {read $h} finally {close $h}]
		set eof		[string first \x1A $bytes]
		set reconstructed	[_reconstruct $custom_maps [encoding convertfrom utf-8 [brotli::decompress [string range $bytes $eof+1 end]]]]
		#puts stderr "reconstructed:\n$reconstructed"
		eval $reconstructed
	}

	#>>>
	proc _load_ziplet {} { #<<<
		set file	[uplevel 1 {info script}]
		set h		[open $file rb]
		set bytes	[try {read $h} finally {close $h}]
		set eof		[string first \u1A $bytes]
		set source	[encoding convertfrom utf-8 [zlib gunzip [string range $bytes $eof+1 end]]]
		uplevel #0 $source
	}

	#>>>
	proc _load_brlet {} { #<<<
		package require brotli
		set file	[uplevel 1 {info script}]
		set h		[open $file rb]
		set bytes	[try {read $h} finally {close $h}]
		set eof		[string first \u1A $bytes]
		set source	[encoding convertfrom utf-8 [brotli::decompress [string range $bytes $eof+1 end]]]
		uplevel #0 $source
	}

	#>>>
	proc _reconstruct {custom_maps in} { #<<<
		string map [list \
			%p		" args \{parse_args \$args \{-requestid -alias -response_headers -alias -timeout \{-default \{\}\} -connect_timeout \{-default \{\}\} -read_timeout \{-default \{\}\} -max_keepalive_age \{-default \{\}\} -max_keepalive_count \{-default \{\}\} " \
			%r		";_service_req -r \$region " \
			{*}$custom_maps \
		] $in
	}

	#>>>
	proc from_camel str { # UseFIPS -> use_FIPS, WriteGetObjectResult -> write_get_object_result, S3Bucket -> s3_bucket, fooEnum1 -> foo_enum1 <<<
		# Two cases:
		#   - An all-caps run, optionally followed by digits, as long as the
		#     next char is caps (so the digits are part of an acronym like S3)
		#     or end of string. Example: "UseFIPS" -> "use" + "FIPS".
		#   - A normal word: a letter followed by 1+ lowercase and optional
		#     trailing digits. Example: "fooEnum1" -> "foo" + "Enum1".
		# Acronym runs keep their original case; normal words lowercase.
		join [lmap {- caps title} [regexp -all -inline \
			{([A-Z]+\d*(?=[A-Z]|$))|([A-Za-z][a-z]+\d*)} $str] \
		{
			if {$title ne {}} {
				string tolower $title
			} else {
				set caps
			}
		}] _
	}

	#>>>
	proc to_camel str { # use_FIPS -> UseFIPS, write_get_object_result -> WriteGetObjectResult <<<
		join [lmap e [split $str _] {
			if {[string is upper $e]} {
				set e
			} else {
				string totitle $e
			}	
		}] {}
	}

	#>>>
	proc _undocument {objectvar args} { #<<<
		upvar 1 $objectvar o
		set path	$args
		json foreach {k v} [json extract $o {*}$path] {
			if {$k in {documentation documentationUrl}} {
				json unset o {*}$path $k
			} elseif {[json type $v] eq "object"} {
				_undocument o {*}$path $k
			}
		}
	}

	#>>>

	proc endpoint args { #<<<
		variable endpoint_cache
		variable default_region
		variable endpoints

		if {![dict exists $endpoint_cache $args]} {
			package require aws::endpoints

			parse_args $args {
				-region			{}
				-service		{-required}
			}

			if {![info exists region]} {set region $default_region}

			set found	0
			json foreach partition [json extract $endpoints partitions] {
				if {[json exists $partition regions $region]} {
					set found	1
					break
				}
			}
			if {!$found} {
				error "Could not find endpoint data for region \"$region\""
			}
			set ei	[json extract $partition defaults]
			if {![json exists $partition services $service]} {
				error "Could not find service defined in partition for region \"$region\""
			}

			# Update with the service defaults
			json foreach {k v} [json extract $partition services $service defaults] {
				json set ei $k $v
			}

			# Update with the region specifics
			json foreach {k v} [json extract $partition services $service endpoints $region] {
				json set ei $k $v
			}

			dict set endpoint_cache $args $ei
		}
		dict get $endpoint_cache $args
	}

	#>>>
	namespace eval _fn { # Functions used by the endpoint routing rules <<<
		namespace path {::parse_args ::rl_json ::aws::helpers}

		proc aws.isVirtualHostableS3Bucket {bucket allowdots} { #<<<
			if {[string length $bucket] < 3} {return 0}
			# TODO: verify the other requirements from https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html?
			if {$allowdots} {
				regexp {^[a-z0-9.-]+$} $bucket
			} else {
				regexp {^[a-z0-9-]+$} $bucket
			}
		}

		#>>>
		proc aws.parseArn arn { #<<<
			# https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazons3.html
			# Matches botocore: split on the first 5 colons into
			# arn/partition/service/region/account/resource, then split resource
			# on any : or / (preserving empty components).
			set parts	[split $arn :]
			if {[llength $parts] < 6 || [lindex $parts 0] ne "arn"} {
				error "Cannot parse arn: \"$arn\""
			}
			lassign $parts - partition service region accountid
			set resource	[join [lrange $parts 5 end] :]
			if {$partition eq "" || $service eq "" || $resource eq ""} {
				error "Invalid ARN: missing required component"
			}
			set resource_ids	[split [string map {: /} $resource] /]
			set resourceId		{[]}
			foreach resource_id $resource_ids {
				json set resourceId end+1 [json string $resource_id]
			}

			json template {
				{
					"region":		"~S:region",
					"accountId":	"~S:accountid",
					"service":		"~S:service",
					"partition":	"~S:partition",
					"resourceId":	"~J:resourceId"
				}
			}
		}

		#>>>
		proc aws.partition {service region} { #<<<
			variable ::aws::partitions
			variable ::aws::endpoints
			upvar 1 p p
			try {
				#puts stderr "aws.partition service: ($service), region: ($region)"
				#if {$region eq "aws-global"} {set region us-east-1}
				#if {![regexp {^[a-z0-9-]+$} $region]} {return null}
				try {
					package require aws::endpoints
				} on error {errmsg options} {
					log error "Could not load aws::endpoints: $errmsg"
				}
				#puts stderr "partitions: [json length $endpoints partitions]"
				set default_partition	{}
				json foreach partition [json extract $endpoints partitions] {
					#puts stderr "Looking in partition ([json get $partition partition]) for ($region)"
					set pid	[json get $partition partition]
					set re	[json get $partition regionRegex]
					#puts stderr "regionRegex: ($re): [regexp $re $region]"
					if {
						[regexp $re $region] ||
						[json exists $partition services $service endpoints $region] ||
						[json exists $partitions $pid regions $region]
					} {
						#json set partition name [json get $partition partition]
						json foreach {k v} [json extract $partitions $pid outputs] {
							json set partition $k $v
						}
						return $partition
					}
					if {$default_partition eq "" && $pid eq "aws"} {
						set default_partition $partition
					}
				}
				# Matches botocore behaviour: fall back to the aws partition when no
				# regionRegex / regions entry matches. Endpoint rules that validate
				# the region separately (e.g. isValidHostLabel) rely on this.
				if {$default_partition ne ""} {
					json foreach {k v} [json extract $partitions aws outputs] {
						json set default_partition $k $v
					}
					return $default_partition
				}
				return null
			} on error {errmsg options} {
				log error "aws.partition lookup error: [dict get $options -errorinfo]"
				return -options $options $errmsg
			} on return partition_result {
				# Have to resort to this because the endpoint_rules for different services use different
				# spellings for the result variable, so we set a fixed name here for our use
				set p(_partition_result)	$partition_result
				#_debug {log notice "_partition_result: $p(_partition_result)"}
				set partition_result
			}
		}

		#>>>
		proc getAttr {doc key} { #<<<
			# getAttr navigates into rule-engine values. Those are JSON objects
			# produced by aws.partition / aws.parseArn / parseURL, except for
			# stringArray params (e.g. dynamodb ResourceArnList) which arrive
			# as plain Tcl lists — those use the bare-index form "[N]".
			if {$doc eq "" || ([json valid $doc] && [json isnull $doc])} {return null}
			if {[regexp {^(\w*)\[([0-9]+)\]$} $key - base idx]} {
				if {$base eq ""} {
					# Bare index: stringArray (Tcl list) member access.
					lindex $doc $idx
				} else {
					json get $doc $base $idx
				}
			} else {
				json get $doc $key
			}
		}

		#>>>
		proc isValidHostLabel {str allowdots} { #<<<
			#puts stderr "isValidHostLabel ($str), $allowdots"
			set valid [if {$allowdots} {
				regexp {^[a-zA-Z0-9.-]+$} $str
			} else {
				regexp {^[a-zA-Z0-9-]+$} $str
			}]
			#puts stderr "\treturning $valid"
			set valid
		}

		#>>>
		proc parseURL uri { #<<<
			try {
				#puts stderr "aws::_fn::parseURL ($uri)"
				set parts	{}
				dict set parts scheme	[reuri get $uri scheme]
				dict set parts host		[reuri get $uri host]
				dict set parts hosttype	[reuri get $uri hosttype]
				dict set parts path		[reuri extract $uri path]
				# Matches botocore parse_url: reject non-http(s) schemes and URLs
				# with queries (rule engine treats null result as parse failure).
				if {[dict get $parts scheme] ni {http https}} {
					error "parseURL: unsupported scheme"
				}
				if {[reuri get $uri query {}] ne ""} {
					error "parseURL: query not supported"
				}
				if {[reuri exists $uri port]} {
					dict append parts host :[reuri get $uri port]
				}
				if {[dict get $parts path] in {/ {}}} {
					dict set parts normalizedPath /
				} else {
					dict set parts normalizedPath [dict get $parts path]/
				}
				dict set parts isIp	[expr {
					[dict get $parts hosttype] in {ipv4 ipv6}
				}]
				json template {
					{
						"scheme":			"~S:scheme",
						"authority":		"~S:host",
						"normalizedPath":	"~S:normalizedPath",
						"path":				"~S:path",
						"isIp":				"~B:isIp"
					}
				} $parts
			} on ok res {
				#puts stderr "::aws::_fn::parseURL returning [json pretty $res]"
				set res
			} on error {errmsg options} {
				#puts stderr "::aws::_fn::parseURL: [dict get $options -errorinfo]"
				return -options $options $errmsg
			}
		}

		#>>>
		proc substring {str start stop reverse} { #<<<
			# Per Smithy rules-engine: start inclusive, stop exclusive. reverse=true
			# indexes from the end. Returns null on out-of-range / non-ASCII input
			# (matches botocore; rule engine treats null as parse failure).
			set len [string length $str]
			if {$start >= $stop || $len < $stop || ![string is ascii $str]} {
				return null
			}
			if {$reverse} {
				string range $str [expr {$len-$stop}] [expr {$len-$start-1}]
			} else {
				string range $str $start [expr {$stop-1}]
			}
		}

		#>>>
		proc uriEncode str { #<<<
			# Per the Smithy rules engine spec: percent-encode everything except
			# [A-Za-z0-9._~-]. reuri's awssig profile follows the same rule.
			reuri encode awssig $str
		}

		#>>>
		proc _e args { #<<<
			set frame	[info frame -1]
			parse_args $args {
				msg			{-required}
				istemplate	{-required}
				lookup		{}
			}
			if {[info exists lookup]} {
				set msg	[lindex $lookup $msg]
			}
			#_debug {log notice "endpoint_rules error leaf: ($msg): [dict get $frame file]:[dict get $frame line]"}
			if {$istemplate} {
				throw terr $msg
			} else {
				error $msg
			}
		}

		#>>>
		proc _r args { #<<<
			set frame	[info frame -1]
			parse_args $args {
				ep		{-required}
				lookup	{}
			}

			if {[info exists lookup]} {
				set ep	[lindex $lookup $ep]
			}
			#_debug {log notice "endpoint_rules result leaf: ($ep): [dict get $frame file]:[dict get $frame line]"}
			return -code return $ep
		}

		#>>>
		proc _t template { #<<<
			upvar 1 p p
			::aws::template $template [array get p]
		}

		#>>>
		proc _a {var args} { #<<<
			upvar 1 p p
			try $args on ok res {
				# Match botocore's evaluate_conditions: result of None (null) or
				# False fails the condition. Empty string is treated as falsy too
				# since getAttr returns "" for missing dict keys / out-of-range
				# indices (the rule engine spec says such lookups return null).
				if {$res eq "" || $res eq "false" || $res eq 0} {return 0}
				if {[json valid $res] && [json isnull $res]} {return 0}
				set p($var) $res
				return 1
			} on error {errmsg options} {
				return 0
			}
		}

		#>>>
	}

	#>>>
	proc _compile_rest-xml_op {ns cmd args} { #<<<
		variable ${ns}::service_def
		variable ${ns}::endpoint_params
		variable ${ns}::service_name_orig
		variable ${ns}::exceptions
		variable ${ns}::responses

		set op	[to_camel $cmd]
		if {![json exists $service_def operations $op]} {
			error "Invalid operation \"$cmd\" for service [namespace tail [namespace current]], must be one of [join [json lmap op [json extract $service_def operations] {
				from_camel $op
			}] {, }]"
		}

		set opdef	[json extract $service_def operations $op]

		set cx_suppress	{
			UseObjectLambdaEndpoint	1
		}
		set cxparams	{}
		set copy_to_cx	{}
		if {[json exists $opdef staticContextParams]} {
			json foreach {k v} [json extract $opdef staticContextParams] {
				dict set cxparams		$k [json get $v value]
				dict set cx_suppress	$k 1
			}
		}

		# Add the operation input params to argspec and input wiring <<<
		if {[json exists $opdef input]} {
			set inputshape	[json extract $service_def shapes [json get $opdef input shape]]
			set op_required	[if {[json exists $inputshape required]} {json get $inputshape required}]

			set argspec			{}
			json foreach {member def} [json extract $inputshape members] {
				set required	[expr {$member in $op_required}]
				if {[json exists $def contextParam]} {
					lappend copy_to_cx $member [json get $def contextParam name]
					dict set cx_suppress $member 1
				}

				set opt		-[aws from_camel $member]
				set settings	[list -name $member]
				if {$required} {lappend settings -required}

				lappend argspec $opt $settings
			}
		}
		# Add the operation input params to argspec and input wiring >>>

		# Add the endpoint context input params to argspec and input wiring <<<
		if {$endpoint_params eq {}} {
			lappend argspec	-region	[list -default $::aws::default_region]
		} else {
			set cx_required	[if {[json exists $endpoint_params required]} {json get $endpoint_params required}]
			_debug {log debug "endpoint_params required: ($cx_required)"}

			json foreach {camel_name details} $endpoint_params {
				set required	[expr {$camel_name in $cx_required}]
				if {[dict exists cx_suppress $camel_name]} continue

				set name		-[aws from_camel $camel_name]
				set settings	{}
				if {[json exists $details builtIn]} {
					switch -exact -- [json get $details builtIn] {
						AWS::Region {
							lappend settings -default $::aws::default_region
						}
					}
				}
				lappend settings -name $camel_name
				if {[json exists $details default]} {
					lappend settings -default [json get $details default]
				} elseif {[json exists $details required] && [json get $details required]} {
					lappend settings -required
				}
				if {0 && [json exists $details documentation]} {
					lappend settings -# [json get $details documentation]
				}
				switch -exact -- [string tolower [json get $details type]] {
					string {}
					boolean {lappend settings -validate {string is boolean -strict}}
					stringarray {}
					default {error "Unhandled endpoint rules param type: \"[json get $details type]\""}
				}
				lappend argspec $name $settings
				lappend copy_to_cx $camel_name $camel_name
			}
		}
		# Add the endpoint context input params to argspec and input wiring >>>

		# Transport-level knobs accepted by every rest-xml op. They're
		# forwarded through the $params dict into _service_req.
		lappend argspec -timeout             [list -name timeout             -default {}]
		lappend argspec -connect_timeout     [list -name connect_timeout     -default {}]
		lappend argspec -read_timeout        [list -name read_timeout        -default {}]
		lappend argspec -max_keepalive_age   [list -name max_keepalive_age   -default {}]
		lappend argspec -max_keepalive_count [list -name max_keepalive_count -default {}]

		# If the response specifies a payload, wire up the -payload alias in argspec <<<
		set post_parse_args	{}
		if {[json exists $opdef output]} {
			set output_shape	[json extract $service_def shapes [json get $opdef output shape]]
			if {[json exists $output_shape payload]} {
				lappend argspec	-payload	{}
				append	post_parse_args	{if {[dict exists $params payload]} {upvar 1 [dict get $params payload] payload}} \n
			}
		}
		# If the response specifies a payload, wire up the -payload alias in argspec >>>

		# Auto-populate idempotency tokens. For rest-xml the input args
		# land in the $params dict keyed by the PascalCase member name,
		# so we inject a dict-set-if-missing after parse_args.
		set idempotency_tokens	{}
		if {[json exists $opdef input shape]} {
			set _ishape	[json get $opdef input shape]
			if {[json exists $service_def shapes $_ishape members]} {
				json foreach {_mname _mdef} [json extract $service_def shapes $_ishape members] {
					if {[json exists $_mdef idempotencyToken] && [json get $_mdef idempotencyToken]} {
						lappend idempotency_tokens $_mname
					}
				}
			}
		}

		set body	""
		append body	{variable service_def} \n
		append body	[list set cxparams	$cxparams] \n
		append body	"parse_args \$args [list $argspec] params\n"
		append body $post_parse_args
		foreach _tok $idempotency_tokens {
			append body "if {!\[dict exists \$params [list $_tok]\]} {dict set params [list $_tok] \[::aws::helpers::_uuid4\]}\n"
		}
		#append body {puts stderr "cxparams: ($cxparams)"} \n
		if {[llength $copy_to_cx] > 0} {
			append body "foreach {in_param cx_param} [list $copy_to_cx] " {{
				if {[dict exists $params $in_param]} {
					dict set cxparams $cx_param [dict get $params $in_param]
				}
			}} \n
		}
		append body	[list dict set params service [list $service_name_orig]] \n
		append body	[list set op $op] \n
		#append body {puts stderr "compute endpoint, first: [timerate {endpoint_rules $cxparams} 1 1]"} \n
		#append body {puts stderr "compute endpoint: [timerate {endpoint_rules $cxparams}]"} \n
		append body {set endpoint	[endpoint_rules $cxparams]} \n
		append body {_debug {log notice "computed endpoint: endpoint_rules($cxparams) -> ($endpoint)"}} \n
		#append body {_debug {log notice "computed endpoint: [json pretty $endpoint]"}} \n
		#append body	[list puts stderr "Would call [namespace tail [namespace current]]->$op: [json pretty $opdef]"] \n
		#if {[json exists $opdef input shape]} {
		#	append body [list puts stderr "Input shape: [json pretty [json extract $service_def shapes [json get $opdef input shape]]]"] \n
		#}
		#if {[json exists $opdef output shape]} {
		#	append body [list puts stderr "Output shape: [json pretty [json extract $service_def shapes [json get $opdef output shape]]]"] \n
		#}

		set params		{}
		set u			{}
		set hm			{}
		set q			{}
		set b			{}
		set x			{}
		#puts stderr -----------------------------------------------------------------------------------
		if {[json exists $opdef input]} {
			aws::build::compile_input \
				-argname_transform	{} \
				-protocol			[json get $service_def metadata protocol] \
				-params				params \
				-cxparams			_cxparams \
				-copy_to_cx			_copy_to_cx \
				-cx_suppress		_cx_suppress \
				-uri_map			u \
				-query_map			q \
				-header_map			hm \
				-payload			b \
				-shapes				[json extract $service_def shapes] \
				-shape				[json get $opdef input shape] \
				-endpoint_params	$endpoint_params \
				-builtins			_builtins

			# TODO: check that _cxparams, _copy_to_cx, _cx_supporess matches with what the code above generated, and remove that code if it does

			set x	[aws::build::compile_xml_input \
				-shapes	[json extract $service_def shapes] \
				-input	[json extract $opdef input]]
			#puts stderr "x: ($x)"
		}

		regsub {^/{Bucket}} [json get $opdef http requestUri] {} requestUri	;# Endpoint rules takes care of this
		append body [string map [list \
			%http_method%	[list [json get $opdef http method]] \
			%requestUri%	[list $requestUri] \
			%expect_status%	[list [expr {[json exists $opdef http responseCode] ? [json get $opdef http responseCode] : 200}]] \
			%response%		[list [if {[info exists response]} {set response}]] \
			%payload%		[list $b] \
			%header_map%	[list $hm] \
			%query_map%		[list $q] \
			%uri_map%		[list $u] \
			%xml_input%		[list $x] \
			%resultWrapper%	[list [if {[info exists w]} {set w}]] \
			%op%			[list $op] \
		] {
			set ei	[list apply [list {endpoint region} {
				set authscheme	[json extract $endpoint properties authSchemes 0]
				if {![json exists $authscheme disableDoubleEncoding]} {
					json set authscheme disableDoubleEncoding false
				}

				set sigver	[json get $authscheme name]
				switch -exact -- $sigver {
					sigv4	{
						if {[json get $endpoint _ service] eq "s3"} {
							set sigver	s3v4
						} else {
							set sigver	v4
						}
					}
					sigv4a	{
						if {[json get $endpoint _ service] eq "s3"} {
							set sigver	s3v4a
						} else {
							set sigver	v4a
						}
					}
				}

				set url		[json get $endpoint url]
				dict create \
					protocols				[list [reuri get $url scheme http]] \
					hostname				[reuri get $url host] \
					url						$url \
					region					[json get $endpoint _ region] \
					credentialScope			[json get $endpoint _ credentialScope] \
					signatureVersions		[list $sigver] \
					disableDoubleEncoding	[json get $authscheme disableDoubleEncoding] \
					signingRegion			[json get $authscheme signingRegion] \
			} ::aws::helpers] $endpoint]

			set path	[string trimright [reuri extract [json get $endpoint url] path] /]
			append path	%requestUri%
			dict with params {}		;# The unpacked key variables are accessed by the request procs through upvar
			# Newer endpoint rules omit signingName when it matches the service's
			# endpointPrefix; fall back to that.
			set signingName	[if {[json exists $endpoint properties authSchemes 0 signingName]} {
				json get $endpoint properties authSchemes 0 signingName
			} else {
				json get $endpoint _ service
			}]
			::aws::_service_req \
				-s			$signingName \
				-m			%http_method% \
				-p			$path \
				-R			%response% \
				-e			%expect_status% \
				-b			%payload% \
				-hm			%header_map% \
				-q			%query_map% \
				-u			%uri_map% \
				-w			%resultWrapper% \
				-x			%xml_input% \
				-handleresp	[list ::aws::_handle_xml_resp $service_def %op%] \
				-payload	payload
		}]
		proc ${ns}::$cmd args $body
		#puts stderr "JIT created ${ns}::$cmd:\n$body"
		list	;# Have the ensemble unknown handler re-dispatch the call now that we've created the handler
	}

	#>>>
	proc template {template dict} { #<<<
		set res	""
		#puts stderr "aws::template ($template), dict: ($dict)"
		#puts stderr "aws::template ($template)"
		foreach {- lit key} [regexp -all -inline {([^\u7b]*)(?:\u7b([^\u7d]+)\u7d)?} $template] {
			#puts stderr "appending lit: ($lit), processing key ($key)"
			switch -regexp -matchvar m -- $key {
				{^(.*?)#(.*)$} {lassign $m - base attr
					_debug {log notice "matched attr syntax: base: ($base), attr: ($attr) ([set -])"}
					if {[dict exists $dict $base] && [json exists [dict get $dict $base] $attr]} {
						set subst	[json get [dict get $dict $base] $attr]
					} elseif {$base eq "partitionResult"} {
						package require aws::endpoints
						variable endpoints
						# Fall back to the default partition - not sure about this
						set subst	[json get $endpoints partitions 0 $attr]
					} else {
						set subst	null
					}
				}
				{^$} {
					set subst	{}
				}
				default {
					set subst	[dict get $dict $key]
				}
			}
			#puts stderr "aws::template appending lit ($lit), key: ($key), subst: ($subst)"
			append res $lit $subst
		}
		#puts stderr "aws::template returning ($res)"
		set res
	}

	#>>>
	proc objecttemplate {object dict} { #<<<
		_debug {log notice "objecttemplate, object: ($object), dict keys: ([dict keys $dict])"}
		#puts stderr "rep: [tcl::unsupported::representation $object]"
		#puts stderr "objecttemplate signingRegion: ([json get $object properties authSchemes 0 signingRegion]), rep: [tcl::unsupported::representation [json get $object properties authSchemes 0 signingRegion]]"
		#puts stderr [json debug $object]
		#set object	"$object "
		#if {[dict exists $dict Region]} {
		#	puts stderr "p(Region): ([dict get $dict Region])"
		#}
		set paths	[lmap e [json keys $object] {list $e}]
		set nextpaths	{}
		while {[llength $paths]} {
			foreach path $paths {
				switch -exact -- [json type $object {*}$path] {
					string {
						#puts stderr "objecttemplate processing string ([json get $object {*}$path]) at path $path\nobject: ($object)"
						json set object {*}$path [json string [::aws::template [json get $object {*}$path] $dict]]
					}
					object {
						lappend nextpaths	{*}[lmap e [json keys $object {*}$path] {list {*}$path $e}]
					}
					array {
						for {set i 0; set len [json length $object {*}$path]} {$i < $len} {incr i} {
							lappend nextpaths [list {*}$path $i]
						}
					}
				}
			}
			set paths		$nextpaths
			set nextpaths	{}
		}
		#puts stderr "template end, object rep: [tcl::unsupported::representation $object]"
		#puts stderr [json debug $object]
		set object
	}

	#>>>
	proc _foreach {iterator_varname args} { # Paginate a service operation, running body per item <<<
		# -itemtype is a plain option (not -alias) because the TYPE_REQUIRED
		# disambiguation check needs to know whether the caller supplied it,
		# which -alias obscures (info exists on an alias reports on the
		# caller's target var, not whether the option was given).
		# -page is -alias: we always write the current page into it; if not
		# supplied, the write becomes a harmless local.
		parse_args $args {
			-collecting		{-boolean}
			-page_size		{}
			-itemtype		{}
			-page			{-alias}
			-result_key		{}
			-type			{}
			svc				{-required}
			command			{-required}
			args			{-name svcargs}
		}

		if {[llength $svcargs] == 0} {
			throw {AWS FOREACH NO_BODY} "An iterator body script is required"
		}
		set body	[lindex $svcargs end]
		set svcargs	[lrange $svcargs 0 end-1]

		upvar 1 $iterator_varname item
		if {[info exists itemtype]} {upvar 1 $itemtype _itemtype_out}

		package require aws::$svc

		set pag_var	::aws::${svc}::paginators
		if {![info exists $pag_var]} {
			throw {AWS FOREACH NOT_PAGINATED} \
				"Service $svc has no paginator metadata (no paginators-1.json in botocore)"
		}
		set paginators	[set $pag_var]
		set op_camel	[to_camel $command]
		if {![dict exists $paginators $op_camel]} {
			throw {AWS FOREACH NOT_PAGINATED} \
				"Operation $svc $command is not paginated"
		}
		set pspec	[dict get $paginators $op_camel]

		set input_tokens	[dict get $pspec input_tokens]
		set output_tokens	[dict get $pspec output_tokens]
		set limit_key		[dict get $pspec limit_key]
		set more_results	[dict get $pspec more_results]
		set item_containers	[dict get $pspec item_containers]

		if {[info exists result_key]} {
			# Accept either the dot-joined form or just the tail path segment.
			set filtered	{}
			foreach container $item_containers {
				lassign $container ctype cpath
				if {$result_key eq [join $cpath .] || $result_key eq [lindex $cpath end]} {
					lappend filtered $container
				}
			}
			if {[llength $filtered] == 0} {
				throw {AWS FOREACH NO_SUCH_KEY} \
					"-result_key \"$result_key\" doesn't match any container for $svc $command (have: [lmap c $item_containers {join [lindex $c 1] .}])"
			}
			set item_containers	$filtered
		}

		if {[llength $item_containers] > 1 && ![info exists itemtype] && ![info exists type]} {
			set types	[lmap c $item_containers {lindex $c 0}]
			throw {AWS FOREACH TYPE_REQUIRED} \
				"Operation $svc $command has multiple item containers ($types); pass -itemtype <var>, -type <itemtype>, or -result_key <key>"
		}

		set page_size_args	{}
		if {[info exists page_size]} {
			if {$limit_key eq ""} {
				throw {AWS FOREACH NO_LIMIT_KEY} \
					"Operation $svc $command has no limit_key; cannot honor -page_size"
			}
			set page_size_args	[list -[from_camel $limit_key] $page_size]
		}

		set reslist			{}
		set next_page_args	{}
		while 1 {
			set breakout 0
			set res	[uplevel 1 [list aws::$svc $command {*}$svcargs {*}$page_size_args {*}$next_page_args]]
			set page	$res

			foreach container $item_containers {
				lassign $container this_itype cpath
				if {[info exists type] && $type ne $this_itype} continue
				if {[info exists itemtype]} {set _itemtype_out $this_itype}
				if {![json exists $res {*}$cpath]} continue
				json foreach item [json extract $res {*}$cpath] {
					try {
						uplevel 1 $body
					} on break {} {
						return $reslist
					} on continue {} {
						continue
					} on return {r o} {
						dict incr o -level 1
						dict set o -code return
						return -options $o $r
					} trap {AWS FOREACH NEXT_PAGE} {} {
						set breakout 1
						break
					} on error {r o} {
						dict incr o -level 1
						return -options $o $r
					} on ok r {
						if {$collecting} {lappend reslist $r}
					}
				}
				if {$breakout} break
			}

			# Termination:
			# 1. Explicit more_results flag present and false → done.
			if {$more_results ne "" && [json exists $res $more_results]} {
				if {![string is true -strict [json get $res $more_results]]} break
			}
			# 2. No (or empty) continuation tokens → done.
			set next_page_args	{}
			set any_token		0
			foreach in_name $input_tokens out_name $output_tokens {
				if {![json exists $res $out_name]} continue
				set tok	[json get $res $out_name]
				if {$tok eq "" || $tok eq "null"} continue
				lappend next_page_args -[from_camel $in_name] $tok
				incr any_token
			}
			if {!$any_token} break
		}

		set reslist
	}

	#>>>
	proc _lmap {iterator_varname args} { # Collecting variant of aws foreach <<<
		tailcall ::aws::_foreach $iterator_varname -collecting {*}$args
	}

	#>>>
	namespace eval build {
		namespace path {::parse_args ::rl_json ::aws::helpers}
		proc compile_xml_transforms args { #<<<
			parse_args $args {
				-shapes		{-required}
				-fetchlist	{-alias}
				-shape		{-required}
				-source		{-default {}}
				-path		{-default {}}
			}

			try {
				set nextkey	[expr {[llength $fetchlist] + 1}]
				set rshape	[json extract $shapes $shape]
				set type	[resolve_shape_type $shapes $shape]
				lappend path	${shape}($type)
				#puts stderr "compile_xml_transforms, type: ($type), path: ($path), payload exists? ([json exists $rshape payload]), location: ([if {[json exists $rshape location]} {json get $rshape location}])"

				switch -exact -- $type {
					list {
						if 0 {
						set typekey	[string toupper [typekey [resolve_shape_type $shapes [json get $rshape member shape]]]]
						#lappend fetchlist [list $nextkey $typekey $source]
						lappend fetchlist [list $nextkey [typekey $type] $source $membertype]
						}

						set membershape	[json get $rshape member shape]
						#set membertype	[resolve_shape_type $shapes $membershape]
						set subfetchlist	{}
						set valuetemplate	[compile_xml_transforms \
							-shapes		$shapes \
							-fetchlist	subfetchlist \
							-shape		$membershape \
							-source		{} \
							-path		$path \
						]
						# Non-flattened AWS lists wrap each element in <member>
						# by default. Flattened lists inline the elements under
						# the list's own tag (which is the structure member's
						# locationName, i.e. our $source), so the xpath collapses
						# to just the source.
						set flat	[json get -default false $rshape flattened]
						if {[json exists $rshape member locationName]} {
							set elemname	[json get $rshape member locationName]
						} elseif {$flat} {
							set elemname	{}
						} else {
							set elemname	member
						}
						set xpath	[expr {$elemname eq "" ? $source : "$source/$elemname"}]
						lappend fetchlist [list $nextkey [typekey $type] $xpath $subfetchlist $valuetemplate]

						set template	"~J:$nextkey"
					}

					structure {
						set template	{{}}
						json foreach {name member} [json extract $rshape members] {
							if {[json exists $member locationName]} {
								set subsource	[json get $member locationName]
							} else {
								set subsource	$name
							}
							if {$source ne ""} {
								set subsource	$source/$subsource
							} else {
								set subsource	$subsource
							}
							json set template $name [compile_xml_transforms \
								-shapes		$shapes \
								-fetchlist	fetchlist \
								-shape		[json get $member shape] \
								-source		$subsource \
								-path		$path \
							]
						}
					}

					map {
						set keytype	[resolve_shape_type $shapes [json get $rshape key shape]]
						if {$keytype ne "string"} {
							error "Unhandled case: map with key type $keytype"
						}
						set valueshape	[json get $rshape value shape]
						#set valuetype	[resolve_shape_type $shapes $valueshape]
						set subfetchlist	{}
						set valuetemplate	[compile_xml_transforms \
							-shapes		$shapes \
							-fetchlist	subfetchlist \
							-shape		$valueshape \
							-source		$valueshape \
							-path		$path \
						]
						lappend fetchlist [list $nextkey [typekey $type] $source [json get $rshape key shape] $subfetchlist $valuetemplate]
						set template	[json string "~J:$nextkey"]
					}

					blob {
						lappend fetchlist [list $nextkey [typekey $type] {*}[if {$source ne {}} {list $source}]]
						set template	[json string "~J:$nextkey"]
					}

					string {
						lappend fetchlist [list $nextkey [typekey $type] {*}[if {$source ne {}} {list $source}]]
						set template	[json string "~J:$nextkey"]
					}

					boolean {
						lappend fetchlist [list $nextkey [typekey $type] {*}[if {$source ne {}} {list $source}]]
						set template	[json string "~J:$nextkey"]
					}

					timestamp {
						lappend fetchlist [list $nextkey [typekey $type] {*}[if {$source ne {}} {list $source}]]
						set template	[json string "~J:$nextkey"]
					}

					integer -
					long -
					double -
					float {
						lappend fetchlist [list $nextkey [typekey $type] {*}[if {$source ne {}} {list $source}]]
						set template	[json string "~J:$nextkey"]
					}

					default {
						error "Unhandled type \"$shape\" -> \"$type\""
					}
				}

				set template
			} trap unwind_compile_xml_transforms {errmsg options} {
				return -options $options $errmsg
			} on error {errmsg options} {
				set prefix	"Error in compile_xml_transforms([join $path ->]):"
				set errmsg	$prefix\n$errmsg
				dict set options -errorinfo $prefix\n[dict get $options -errorinfo]
				dict set options -errorcode [list unwind_compile_xml_transforms [dict get $options -errorcode]]
				return -options $options $errmsg
			}
		}

		#>>>
		proc resolve_shape_type {shapes shape} { #<<<
			if {[json exists $shapes $shape type]} {
				return [json get $shapes $shape type]
			}
			# TODO: Some defense against definition loops?
			tailcall resolve_shape_type $shapes [json get $shapes $shape shape]
		}

		#>>>
		proc typekey type { #<<<
			switch -exact -- $type {
				string    {set typekey s}
				boolean   {set typekey b}
				blob      {set typekey x}
				structure {set typekey t}
				list      {set typekey l}
				map       {set typekey m}
				timestamp {set typekey c}
				integer - long - double - float {set typekey n}
				default {
					error "Unhandled element type \"$type\""
				}
			}
			set typekey
		}

		#>>>
		proc build_rewriter_spec {shapes shape protocol {seen {}}} { #<<<
			# Walk a shape tree and return a rewriter spec for _tx_rewrite, or
			# "" when the user's value can pass through unchanged. Used for
			# members whose value is supplied as a JSON fragment (structures,
			# lists, maps, unions, documents) — the rewriter walks into the
			# fragment at runtime to apply per-position transforms such as
			# blob base64 encoding, jsonName renames, and timestamp
			# conversions.
			if {[llength [lsearch -all $seen $shape]] >= 5} {return ""}
			lappend seen $shape
			set def		[json extract $shapes $shape]
			# Document types accept arbitrary JSON and are always pass-through.
			if {[json get -default false $def document]} {return ""}
			set type	[resolve_shape_type $shapes $shape]
			switch -exact -- $type {
				blob {
					return blob
				}
				timestamp {
					set fmt	[json get -default "" $def timestampFormat]
					if {$fmt eq ""} {
						set fmt	[expr {$protocol in {json rest-json} ? "unixTimestamp" : "iso8601"}]
					}
					list ts $fmt
				}
				float - double {
					return float
				}
				structure - union {
					set has_changes	0
					set members		{}
					json foreach {ck mdef} [json extract $def members] {
						if {[json exists $mdef location]} continue ;# header/uri/querystring — not body
						set loc	[if {[json exists $mdef jsonName]} {
							json get $mdef jsonName
						} elseif {[json exists $mdef locationName]} {
							json get $mdef locationName
						} else {
							set ck
						}]
						set sub	[build_rewriter_spec $shapes [json get $mdef shape] $protocol $seen]
						if {$sub ne "" || $loc ne $ck} {set has_changes 1}
						lappend members $ck $loc $sub
					}
					if {!$has_changes} {return ""}
					list struct $members
				}
				list {
					set sub	[build_rewriter_spec $shapes [json get $def member shape] $protocol $seen]
					if {$sub eq ""} {return ""}
					list list $sub
				}
				map {
					set sub	[build_rewriter_spec $shapes [json get $def value shape] $protocol $seen]
					if {$sub eq ""} {return ""}
					list map $sub
				}
				default {
					return ""
				}
			}
		}

		#>>>
		proc compile_query_spec {shapes shape protocol {member_flattened 0} {seen {}}} { #<<<
			# Build a minimal spec describing how to flatten a shape into query
			# params (for the query and ec2 protocols). Returns:
			#   ""                         scalar value, emitted directly
			#   {list <memberName> <flat> <subspec>}
			#   {struct {data_key serialized subspec data_key serialized subspec ...}}
			#   {map <flat> <key_name> <key_subspec> <val_name> <val_subspec>}
			# where <flat> is 1 if list items carry no .member. infix, and
			# data_key is what the caller uses in the Tcl dict / JSON object
			# (the member's Python name) while serialized is the wire name.
			# For maps, <key_name>/<val_name> are the serialized names of the
			# pair (default "key"/"value"; overridden by key.locationName /
			# value.locationName).
			#
			# member_flattened is the `flattened` flag from the parent
			# structure's member reference (e.g. for "FlattenedListArg":
			# {"shape":"StringList","flattened":true}, the flag lives on the
			# member, not on StringList). Shape-level `flattened` is also
			# honoured.
			#
			# seen tracks shape names currently being compiled. Recursive shapes
			# (e.g. StructArg -> RecursiveArg:StructArg) are allowed to a fixed
			# depth, after which we truncate to "" (scalar passthrough); the
			# value at runtime is then emitted opaquely. A depth of 5 covers
			# all real AWS services we've seen; arbitrary recursion would need
			# a proper ref/refs-table scheme.
			set max_recursion	5
			if {[llength [lsearch -all $seen $shape]] >= $max_recursion} {return ""}
			lappend seen $shape
			set def		[json extract $shapes $shape]
			set type	[resolve_shape_type $shapes $shape]
			switch -exact -- $type {
				list {
					set member_def	[json extract $def member]
					set member_shape	[json get $member_def shape]
					# ec2 lists are always flattened; query lists are flattened
					# when either the shape or the member reference has the
					# flattened flag.
					set flat	[expr {
						$protocol eq "ec2" ||
						$member_flattened ||
						[json get -default false $def flattened]
					}]
					# Element locationName for the .member.N variant of query;
					# ec2 re-uses the parent prefix so this is unused there.
					set member_name	[if {[json exists $member_def locationName]} {
						json get $member_def locationName
					} else {
						# botocore default for query: "member"
						return -level 0 member
					}]
					list list $member_name $flat [compile_query_spec $shapes $member_shape $protocol 0 $seen]
				}
				structure {
					set members	{}
					json foreach {cname mdef} [json extract $def members] {
						set loc	[if {[json exists $mdef locationName]} {
							json get $mdef locationName
						} else {
							set cname
						}]
						if {$protocol eq "ec2"} {
							if {[json exists $mdef queryName]} {
								set loc	[json get $mdef queryName]
							} else {
								set loc	[string toupper $loc 0 0]
							}
						}
						set child_flat	[json get -default false $mdef flattened]
						lappend members $cname $loc [compile_query_spec $shapes [json get $mdef shape] $protocol $child_flat $seen]
					}
					list struct $members
				}
				map {
					set key_def		[json extract $def key]
					set val_def		[json extract $def value]
					set key_name	[json get -default key $key_def locationName]
					set val_name	[json get -default value $val_def locationName]
					set flat		[expr {
						$member_flattened ||
						[json get -default false $def flattened]
					}]
					set key_spec	[compile_query_spec $shapes [json get $key_def shape] $protocol 0 $seen]
					set val_spec	[compile_query_spec $shapes [json get $val_def shape] $protocol 0 $seen]
					list map $flat $key_name $key_spec $val_name $val_spec
				}
				boolean {
					return bool
				}
				blob {
					return blob
				}
				timestamp {
					# Query/ec2 default is iso8601. unixTimestamp / rfc822 can
					# be selected via the shape's timestampFormat attribute.
					set fmt	[json get -default iso8601 $def timestampFormat]
					list timestamp $fmt
				}
				default {
					return ""
				}
			}
		}

		#>>>
		proc compile_input args { #<<<
			parse_args $args {
				-argname			{}
				-argname_transform	{-default aws::from_camel}
				-protocol			{-required}
				-params				{-alias}
				-cxparams			{-alias}
				-copy_to_cx			{-alias}
				-cx_suppress		{-alias}
				-uri_map			{-alias}
				-query_map			{-alias}
				-header_map			{-alias}
				-payload			{-alias}
				-shapes				{-required}
				-shape				{-required}
				-endpoint_params	{-required}
				-builtins			{-alias}
				-transforms			{-alias}
			}

			#puts stderr "compile_input, argname: ([if {[info exists argname]} {set argname}]), shape: ($shape)"
			set input	[json extract $shapes $shape]
			set type	[resolve_shape_type $shapes $shape]

			#puts stderr "compile_input, type: [json pretty $input]"
			switch -- $type {
				structure - union {
					# Only unfold the top level structure into params, just take sub-structures as json
					if {[info exists argname]} {
						# Nested structure/union: register a rewriter if any
						# member needs transformation (blob encoding, jsonName
						# rename, nested timestamp, etc.). Otherwise pass the
						# user's JSON fragment through untouched.
						set rspec	[build_rewriter_spec $shapes $shape $protocol]
						if {$rspec ne ""} {
							lappend transforms [list rewrite $argname $rspec]
							return [json string "~J:_tx_$argname"]
						}
						return [json string "~J:$argname"]
					}

					set template_obj	{{}}
					json foreach {camel_name member_def} [json extract $input members] {
						set name	[if {$argname_transform eq ""} {set camel_name} else {{*}$argname_transform $camel_name}]
						if {[json exists $member_def contextParam]} {
							lappend copy_to_cx $name [json get $member_def contextParam name]
							dict set cx_suppress $camel_name 1
						}
						if {[json exists $member_def builtIn]} {
							lappend builtins	$name [json get $member_def builtIn]
						}
						set argspec	{}
						if {[json exists $input required] && $camel_name in [json get $input required]} {
							lappend argspec -required
						}
						if {
							[resolve_shape_type $shapes [json get $member_def shape]] eq "boolean" ||
							(
								[json exists $shapes [json get $member_def shape]] &&
								[json get $shapes [json get $member_def shape] type] eq "boolean"
							)
						} {
							lappend argspec -boolean
						}
						lappend params	-$name $argspec
						if {[json exists $member_def locationName]} {
							set locationName	[json get $member_def locationName]
						} else {
							set locationName	$camel_name
						}
						if {[json exists $member_def location]} {
							switch -- [json get $member_def location] {
								uri	{
									lappend uri_map	$locationName $name
								}
								querystring {
									lappend query_map	$locationName $name {}
								}
								headers {
									lappend header_map	$locationName* $name
								}
								header {
									lappend header_map	$locationName $name
								}
								default {
									error "Unhandled location for $camel_name: ([json get $member_def location])"
								}
							}
						} elseif {$protocol in {json rest-json rest-xml}} {
							if {[json get $member_def shape] in {Expression Expressions AttributeFilterList AttributeFilter}} {
								json set template_obj $locationName [json string "~J:$name"]
							} else {
								#puts stderr "Recursing into shape [json get $member_def shape]"
								json set template_obj $locationName [compile_input \
									-protocol			$protocol \
									-argname			$name \
									-argname_transform	$argname_transform \
									-params				params \
									-cxparams			cxparams \
									-copy_to_cx			copy_to_cx \
									-cx_suppress		cx_suppress \
									-uri_map			uri_map \
									-query_map			query_map \
									-header_map			header_map \
									-payload			payload \
									-shapes				$shapes \
									-shape				[json get $member_def shape] \
									-endpoint_params	{{}} \
									-builtins			builtins \
									-transforms			transforms \
								]
							}
						} elseif {$protocol in {query ec2}} {
							# ec2 protocol capitalizes the first letter of the
							# serialized name (queryName overrides this entirely).
							if {$protocol eq "ec2"} {
								if {[json exists $member_def queryName]} {
									set serialized	[json get $member_def queryName]
								} else {
									set serialized	[string toupper $locationName 0 0]
								}
							} else {
								set serialized	$locationName
							}
							set member_flat	[json get -default false $member_def flattened]
							set spec	[compile_query_spec $shapes [json get $member_def shape] $protocol $member_flat]
							lappend query_map $serialized $name $spec
						} else {
							error "Unhandled protocol: ($protocol)"
						}
					}
				}
				timestamp {
					# Resolve the wire format: explicit shape-level
					# timestampFormat wins; otherwise json/rest-json default to
					# unixTimestamp, rest-xml/query/ec2 default to iso8601.
					set fmt	[json get -default "" $input timestampFormat]
					if {$fmt eq ""} {
						set fmt	[expr {$protocol in {json rest-json} ? "unixTimestamp" : "iso8601"}]
					}
					switch -exact -- $fmt {
						unixTimestamp {
							lappend transforms [list ts_epoch $argname]
							set template_obj	[json string "~N:_tx_$argname"]
						}
						iso8601 {
							lappend transforms [list ts_iso $argname]
							set template_obj	[json string "~S:_tx_$argname"]
						}
						rfc822 {
							lappend transforms [list ts_rfc822 $argname]
							set template_obj	[json string "~S:_tx_$argname"]
						}
						default {
							set template_obj	[json string "~S:$argname"]
						}
					}
				}
				character -
				string {
					set template_obj	[json string "~S:$argname"]
				}
				map - list {
					# User value is a JSON fragment. Register a rewriter if the
					# elements/values need per-position transformation.
					set rspec	[build_rewriter_spec $shapes $shape $protocol]
					if {$rspec ne ""} {
						lappend transforms [list rewrite $argname $rspec]
						set template_obj	[json string "~J:_tx_$argname"]
					} else {
						set template_obj	[json string "~J:$argname"]
					}
				}
				integer -
				long {
					set template_obj	[json string "~N:$argname"]
				}
				float -
				double {
					# JSON bodies need NaN/Infinity wrapped as strings; normal
					# numeric values pass through.
					lappend transforms [list float $argname]
					set template_obj	[json string "~J:_tx_$argname"]
				}
				boolean {
					set template_obj	[json string "~B:$argname"]
				}
				blob {
					lappend transforms [list blob $argname]
					set template_obj	[json string "~S:_tx_$argname"]
				}
				default {
					error "Unhandled type \"[json get $input type]\""
					if {![json exists $shapes [json get $input type]]} {
						error "Unhandled type \"[json get $input type]\""
					}
					set template_obj	[compile_input \
						-protocol			$protocol \
						-argname			$argname \
						-argname_transform	$argname_transform \
						-params				params \
						-cxparams			cxparams \
						-copy_to_cx			copy_to_cx \
						-cx_suppress		cx_suppress \
						-uri_map			uri_map \
						-query_map			query_map \
						-header_map			header_map \
						-payload			payload \
						-shapes				$shapes \
						-shape				[json get $input type] \
						-endpoint_params	{{}} \
						-builtins			builtins \
						-transforms			transforms \
					]
				}
			}

			if {[json exists $input payload]} {
				# Honour argname_transform so the payload var name matches the
				# parse_args -name the enclosing op proc uses. Without this the
				# rest-xml lazy-compile path (which passes -argname_transform {})
				# ends up with parse_args binding PascalCase (Body) while payload
				# is snake_case (body), and _service_req can't find the content.
				set payload	[if {$argname_transform eq ""} {
					json get $input payload
				} else {
					{*}$argname_transform [json get $input payload]
				}]
			}

			# Add the endpoint context input params to argspec and input wiring <<<
			if {$endpoint_params eq {} && ![dict exists $params -region]} {
				lappend params		-region	[list -default $::aws::default_region]
				lappend builtins	region AWS::Region
			} else {
				set cx_required	[if {[json exists $endpoint_params required]} {json get $endpoint_params required}]
				_debug {log debug "endpoint_params required: ($cx_required)"}

				json foreach {camel_name details} $endpoint_params {
					if {[dict exists cx_suppress $camel_name]} continue
					set required	[expr {$camel_name in $cx_required}]

					set name		[aws from_camel $camel_name]
					set settings	{}
					if {[json exists $details builtIn]} {
						lappend builtins	$name	[json get $details builtIn]
					}
					if {[json exists $details default]} {
						lappend settings -default [json get $details default]
					} elseif {[json exists $details required] && [json get $details required]} {
						lappend settings -required
					}
					if {0 && [json exists $details documentation]} {
						lappend settings -# [json get $details documentation]
					}
					switch -exact -- [string tolower [json get $details type]] {
						string {}
						boolean {lappend settings -validate {string is boolean -strict}}
						stringarray {}
						default {error "Unhandled endpoint rules param type: \"[json get $details type]\""}
					}
					lappend params -$name $settings
					lappend copy_to_cx $name $camel_name
				}
			}
			# Add the endpoint context input params to argspec and input wiring >>>

			set template_obj
		}

		#>>>
		proc _compile_xml_shape {shapes shape} { #<<<
			set res	{}
			set type	[resolve_shape_type $shapes $shape]
			switch -exact -- $type {
				structure {
					json foreach {member inf} [json extract $shapes $shape members] {
						set membershape	[json get $inf shape]
						set membertype	[resolve_shape_type $shapes $membershape]
						if {$membertype in {structure list map}} {
							set children	[_compile_xml_shape $shapes $membershape]
						} else {
							set children	{}
						}
						lappend res $member $children
					}
				}

				map {
					set member	[json extract $shapes $shape]
					if {[json exists $member locationName]} {
						set locationName	[json get $member locationName]
					} else {
						set locationName	entry
					}
					if {[json exists $member key locationName]} {
						set keyname			[json get $member key locationName]
					} else {
						set keyname			key
					}
					if {[json exists $member value locationName]} {
						set valuename		[json get $member value locationName]
					} else {
						set valuename		value
					}
					lappend res =$locationName [list $keyname $valuename [_compile_xml_shape $shapes [json get $member value shape]]]
				}

				list {
					set member	[json extract $shapes $shape member]
					if {[json exists $member locationName]} {
						set locationName	[json get $member locationName]
					} else {
						set locationName	[json get $member shape]
					}
					lappend res *$locationName [_compile_xml_shape $shapes [json get $member shape]]
				}

				default {
				}
			}
			set res
		}

		#>>>
		proc compile_xml_input args { #<<<
			parse_args $args {
				-shapes		{-required}
				-input		{-required}
			}

			set shape	[json get $input shape]
			if {[json exists $input locationName]} {
				set locationName	[json get $input locationName]
				set xmlns			[json get $input xmlNamespace uri]
				set bodyshape		[json get $input shape]
			} else {
				json foreach {name member} [json extract $shapes $shape members] {
					if {![json exists $member location]} {
						if {[json exists $member locationName]} {
							set locationName	[json get $member locationName]
						} else {
							set locationName	$name
						}

						if {[json exists $member xmlNamespace uri]} {
							set xmlns		[json get $member xmlNamespace uri]
						} else {
							set xmlns		{}
						}
						set bodyshape	[json get $member shape]
						break
					}
				}
			}
			if {[info exists bodyshape]} {
				list $locationName $xmlns [_compile_xml_shape $shapes $bodyshape]
			}
		}

		#>>>
	}
}

namespace eval ::tcl::mathfunc {
	proc aws_b val { #<<<
		if {[string is boolean -strict $val]} {
			set val
		} elseif {[json valid $val]} {
			json exists $val
		} else {
			expr {$val ne ""}
		}
	}

	#>>>
}


# Hook into the tclreadline tab completion
namespace eval ::tclreadline {
	proc complete(aws) {text start end line pos mod} { #<<<
		if {$pos == 1} {
			set dir	[file join $::aws::dir aws]
			set services	[lmap e [glob -nocomplain -type f -tails -directory $dir *.tm] {
				lindex [regexp -inline {^(.*?)-} $e] 1
			}]
			#puts "searching dir $dir for service packages: $services"
			# TODO: add in the non-service commands
			return [CompleteFromList $text $services]
		}
		try {
			set prefline	[string range $line 0 $start]
			package require aws::[Lindex $prefline 1]
		} on error {errmsg options} {
			return ""
		}
		# Hand off to the ensemble completer
		package require tclreadline::complete::ensemble
		::tclreadline::complete::ensemble ::aws $text $start $end $line $pos $mod
	}

	#>>>
}

# vim: ft=tcl foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
