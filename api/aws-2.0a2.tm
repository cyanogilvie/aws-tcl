# AWS signature version 4: https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html
# All services support version 4, except SimpleDB which requires version 2

package require rl_http
package require urlencode
package require uri
package require parse_args
package require tdom
package require rl_json
package require chantricks

namespace eval aws {
	namespace export *
	namespace ensemble create -prefixes no -unknown {apply {
		{cmd subcmd args} {package require aws::$subcmd; return}
	}}

	variable debug			false

	variable default_region	[if {
		[info exists ::env(HOME)] &&
		[file readable [file join $::env(HOME) .aws/config]]
	} {
		package require inifile
		set ini	[::ini::open [file join $::env(HOME) .aws/config]]
		try {
			::ini::value $ini default region
		} finally {
			::ini::close $ini
			unset -nocomplain ini
		}
	} else {
		return -level 0 us-east-1
	}]

	variable dir	[file dirname [file normalize [info script]]]

	namespace eval helpers {
		variable cache {}
		variable creds

		namespace path {
			::rl_json
			::parse_args
			::aws
		}

		variable maxrate		50		;# Hz
		variable ratelimit		50
		variable last_slowdown	0

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

		# Ensure that $script is run no more often than $hz / sec
		proc ratelimit {hz script} { #<<<
			variable _ratelimit_previous_script
			set delay	[expr {entier(ceil(1000000.0/$hz))}]
			if {[info exists _ratelimit_previous_script] && [dict exists $_ratelimit_previous_script $script]} {
				set remaining	[expr {$delay - ([clock microseconds] - [dict get $_ratelimit_previous_script $script])}]
				if {$remaining > 0} {
					after [expr {$remaining / 1000}]
				}
			}
			dict set _ratelimit_previous_script $script	[clock microseconds]
			catch {uplevel 1 $script} res options
			dict incr options -level 1
			return -options $options $res
		}

		#>>>
		proc sign {K str} { #<<<
			package require hmac
			binary encode base64 [hmac::HMAC_SHA1 $K [encoding convertto utf-8 $str]]
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
				package require hmac
				binary encode hex [hmac::H sha256 $bytes]
			}

			#>>>
		}

		#>>>
		proc sigv2 args { #<<<
			global env

			parse_args::parse_args $args {
				-variant			{-enum {v2 s3} -default v2}
				-method				{-required}
				-service			{-required}
				-path				{-required}
				-scheme				{-default http}
				-headers			{-default {}}
				-params				{-default {}}
				-content_md5		{-default {}}
				-content_type		{-default {}}
				-body				{-default {}}
				-sig_service		{-default {}}

				-out_url			{-alias}
				-out_headers		{-alias}
				-out_sts			{-alias}
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
				set urlv	[lmap e [split [string trim $path /] /] {urlencode rfc_urldecode -- $e}]
				set canonized_path	/[join [lmap e $urlv {urlencode rfc_urlencode -part path -- $e}] /]
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

			set out_url			$scheme://$service.amazonaws.com$canonized_path[urlencode encode_query $params]

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

			package require hmac
			set amzDate		[amz-date $date]
			set kDate		[hmac::HMAC_SHA256 [encoding convertto utf-8 AWS4$aws_key] [encoding convertto utf-8 $amzDate]]
			set kRegion		[hmac::HMAC_SHA256 $kDate       [encoding convertto utf-8 $region]]
			set kService	[hmac::HMAC_SHA256 $kRegion     [encoding convertto utf-8 $service]]
			hmac::HMAC_SHA256 $kService    [encoding convertto utf-8 aws4_request]
		}

		#>>>
		proc sigv4 args { #<<<
			global env

			parse_args::parse_args $args {
				-variant			{-enum {v4 s3v4} -default v4}
				-method				{-required}
				-endpoint			{-required}
				-sig_service		{-default {}}
				-region				{-default us-east-1}
				-credential_scope	{-default ""}
				-path				{-required}
				-scheme				{-default http}
				-headers			{-default {}}
				-params				{-default {}}
				-content_type		{-default {}}
				-body				{-default {}}
				-algorithm			{-enum {AWS4-HMAC-SHA256} -default AWS4-HMAC-SHA256}

				-out_url			{-alias}
				-out_headers		{-alias}
				-out_sts			{-alias}

				-date				{-# {Fake the date - for test suite}}
				-out_creq			{-alias -# {internal - used for test suite}}
				-out_authz			{-alias -# {internal - used for test suite}}
				-out_sreq			{-alias -# {internal - used for test suite}}
			}

			set creds		[get_creds]
			set aws_id		[dict get $creds access_key]
			set aws_key		[dict get $creds secret]
			set aws_token	[dict get $creds token]

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

			set aws_encode {s { #<<<
				foreach {- ok quote} [regexp -all -inline {([A-Za-z0-9_.~-]*)([^A-Za-z0-9_.~-]+)?} $s] {
					append out $ok
					if {$quote ne ""} {
						binary scan [encoding convertto utf-8 $quote] cu* byteslist
						foreach byte $byteslist {
							append out [format %%%02X $byte]
						}
					}
				}
				set out
			}}
			#>>>

			# Task1: Compile canonical request <<<
			# Credential scope <<<
			set fq_credential_scope	[amz-date $date]/[string tolower $credential_scope/$sig_service/aws4_request]
			# Credential scope >>>

			# Produce urlv: a list of fully decoded path elements, and canonized_path: a fully-encoded and normalized path <<<
			set urlv	{}
			if {[string trim $path /] eq ""} {
				set canonical_uri	/
			} else {
				set urlv	[lmap e [split [string trimleft $path /] /] {urlencode rfc_urldecode -- $e}]
				if {$sig_service eq "s3"} {
					set n_urlv	$urlv
				} else {
					# TODO: properly normalize path according to RFC 3986 section 6 - does not apply to s3
					set n_urlv	{}
					foreach e $urlv {
						set skipped	0
						switch -- $e {
							. - ""		{set skipped 1}
							..			{set n_urlv	[lrange $n_urlv 0 end-1]}
							default		{lappend n_urlv $e}
						}
					}
					if {$skipped} {lappend n_urlv ""}		;# Compensate for the switch on {. ""} stripping all the slashes off the end of the uri
				}
				set canonical_uri	/[join [lmap e $n_urlv {
					if {$sig_service eq "s3"} {
						apply $aws_encode $e
					} else {
						# Services other than S3 have to have the path elements encoded twice according to the documentation, but not the test vectors...
						#apply $aws_encode [apply $aws_encode $e]
						apply $aws_encode $e
					}
				}] /]
				if {$sig_service eq "s3" && [string index $path end] eq "/" && [string index $canonical_uri end] ne "/"} {
					append canonical_uri	/
				}
			}
			#>>>

			# Canonical query string <<<
			#if {[info exists aws_token]} {
			#	# Some services require the token to be added to th canonical request, others require it appended
			#	switch -- $sig_service {
			#		?? {
			#			lappend params X-Amz-Security-Token	$aws_token
			#		}
			#	}
			#}

			if {[llength $params] == 0} {
				set canonical_query_string	""
			} else {
				set paramsort {{a b} { #<<<
					# AWS sort wants sorting on keys, with values as tiebreaks
					set kc	[string compare [lindex $a 0] [lindex $b 0]]
					switch -- $kc {
						1 - -1	{ set kc }
						default { string compare [lindex $a 1] [lindex $b 1] }
					}
				}}

				#>>>

				set canonical_query_string	[join [lmap e [lsort -command [list apply $paramsort] [lmap {k v} $params {list $k $v}]] {
					lassign $e k v
					format %s=%s [apply $aws_encode $k] [apply $aws_encode $v]
				}] &]
			}

			#if {[info exists aws_token]} {
			#	# Some services require the token to be added to th canonical request, others require it appended
			#	switch -- $sig_service {
			#		?? {
			#			lappend params X-Amz-Security-Token	$aws_token
			#		}
			#	}
			#}
			# Canonical query string >>>

			# Canonical headers <<<
			set out_headers		$headers
			if {!$have_date_header} {
				lappend out_headers	x-amz-date	[amz-datetime $date]
			}

			if {$content_type ne ""} {
				lappend out_headers content-type $content_type
			}

			if {"host" ni [lmap {k v} $out_headers {string tolower $k}]} {
				#log notice "Appending host header" {{"header":{"host":"~S:endpoint"}}}
				lappend out_headers host $endpoint		;# :authority for HTTP/2
			}
			if {$aws_token ne ""} {
				#log notice "Appending aws_token header" {{"header":{"X-Amz-Security-Token":"~S:aws_token"}}}
				lappend out_headers X-Amz-Security-Token	$aws_token
			}

			if {$variant eq "s3v4"} {
				if {"x-amz-content-sha256" ni [lmap {k v} $headers {set k}]} {
					# TODO: consider caching the sha256 of the empty body
					lappend out_headers x-amz-content-sha256	[hash AWS4-HMAC-SHA256 $body]
				}
			}

			set t_headers	{}
			foreach {k v} $out_headers {
				dict lappend t_headers $k $v
			}

			set canonical_headers	""
			set signed_headers		{}
			foreach {k v} [lsort -index 0 -stride 2 -nocase $t_headers] {
				set h	[string tolower [string trim $k]]
				#if {$h in {content-legnth}} continue		;# Problem with test vectors?
				lappend signed_headers	$h
				append canonical_headers	"$h:[join [lmap e $v {regsub -all { +} [string trim $e] { }}] ,]\n"
				#log debug "Adding canonical header" {{"h":"~S:h","canonical_headers":"~S:canonical_headers","signed_headers":"~S:signed_headers"}}
			}
			set signed_headers	[join $signed_headers ";"]
			# Canonical headers >>>

			set hashed_payload	[hash $algorithm $body]

			set canonical_request	"[string toupper $method]\n$canonical_uri\n$canonical_query_string\n$canonical_headers\n$signed_headers\n$hashed_payload"
			#log debug "canonical request" {{"creq": "~S:canonical_request"}}
			#puts stderr "canonical request:\n$canonical_request"
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
			package require hmac
			set signing_key	[sigv4_signing_key -aws_key $aws_key -date $date -region $region -service $sig_service]
			set signature	[binary encode hex [hmac::HMAC_SHA256 $signing_key [encoding convertto utf-8 $string_to_sign]]]
			#puts stderr "sig:\n$signature"
			# Task3: Calculate signature >>>


			set authorization	"$algorithm Credential=$aws_id/$fq_credential_scope, SignedHeaders=$signed_headers, Signature=$signature"
			set out_authz		$authorization
			lappend out_headers	Authorization $authorization

			set url			$scheme://$endpoint$canonical_uri[urlencode encode_query $params]
			set out_url		$url
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
				}
				#>>>
			} else { # Guess XML <<<
				dom parse [$h body] doc
				try {
					if {$xml_ns ne ""} {
						$doc selectNodesNamespaces [list a $xml_ns]
					}
					$doc documentElement root
					#log notice "AWS error:\n[$root asXML -indent 4]"
					if {[$root nodeName] eq "Error"} {
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
				-scheme				{-default http}
				-headers			{-default {}}
				-params				{-default {}}
				-content_type		{-default {}}
				-body				{-default {}}
				-xml_ns				{-default {}}
				-response_headers	{-alias}
				-status				{-alias}
				-sig_service		{-default {}}
				-version			{-enum {v4 v2 s3 s3v4} -default v4 -# {AWS signature version}}
				-region				{-required}
				-credential_scope	{-default ""}
				-expecting_status	{-default 200}
			}

			switch -- $version {
				s3 - v2 {
					sigv2 \
						-variant		$version \
						-method			$method \
						-service		$service \
						-path			$path \
						-scheme			$scheme \
						-headers		$headers \
						-params			$params \
						-content_type	$content_type \
						-body			$body \
						-sig_service	$sig_service \
						-out_url		signed_url \
						-out_headers	signed_headers \
						-out_sts		string_to_sign
				}

				v4 - s3v4 {
					sigv4 \
						-variant			$version \
						-method				$method \
						-endpoint			$endpoint \
						-sig_service		$sig_service \
						-region				$region \
						-path				$path \
						-scheme				$scheme \
						-headers			$headers \
						-params				$params \
						-content_type		$content_type \
						-body				$body \
						-credential_scope	$credential_scope \
						-out_url			signed_url \
						-out_headers		signed_headers \
						-out_sts			string_to_sign
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
			package require chantricks
			rl_http instvar h $method $signed_url \
				-timeout   20 \
				-keepalive 1 \
				-headers   $signed_headers \
				-tapchan	[list ::chantricks::tapchan [list apply {
					{name chan op args} {
						::aws::helpers::_debug {
							set ts		[clock microseconds]
							set s		[expr {$ts / 1000000}]
							set tail	[string trimleft [format %.6f [expr {($ts % 1000000) / 1e6}]] 0]
							set ts_str	[clock format $s -format "%Y-%m-%dT%H:%M:%S${tail}Z" -timezone :UTC]
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
				}] rl_http_$signed_url] \
				-data      $body

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
			variable ratelimit
			variable last_slowdown
			variable maxrate

			parse_args::parse_args $args {
				-scheme				{-default http}
				-headers			{-default {}}
				-params				{-default {}}
				-content_type		{-default {}}
				-body				{-default {}}
				-xml_ns				{-default {}}
				-response_headers	{-alias}
				-status				{-alias}
				-sig_service		{-default {}}
				-version			{-enum {v4 v2 s3 s3v4} -default v4 -# {AWS signature version}}
				-retries			{-default 3}
				-region				{-required}
				-credential_scope	{-default ""}
				-expecting_status	{-default 200}
			}

			if {$ratelimit < $maxrate && [clock seconds] - $last_slowdown > 10} {
				set ratelimit		[expr {min($maxrate, int($ratelimit * 1.1))}]
				log notice "aws req ratelimit recovery to $ratelimit"
				set last_slowdown	[clock seconds]
			}

			for {set try 0} {$try < $retries} {incr try} {
				try {
					ratelimit $ratelimit {
						return [_req $method $endpoint $path \
							-region				$region \
							-credential_scope	$credential_scope \
							-expecting_status	$expecting_status \
							-headers			$headers \
							-params				$params \
							-content_type		$content_type \
							-body				$body \
							-response_headers	response_headers \
							-status				status \
							-scheme				$scheme \
							-xml_ns				$xml_ns \
							-sig_service		$sig_service \
							-version			$version \
						]
					}
				} trap {AWS InternalError} {errmsg options} {
					continue
				} trap {AWS ServiceUnavailable} {errmsg options} - trap {AWS SlowDown} {errmsg options} {
					set ratelimit		[expr {max(1, int($ratelimit * 0.9))}]
					log notice "aws req got [dict get $options -errorcode], ratelimit now: $ratelimit"
					set last_slowdown	[clock seconds]
					after 200
					continue
				}
			}

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
		global env
		variable creds

		if {
			[info exists creds] &&
			[dict exists $creds expires] &&
			[dict get $creds expires] - [clock seconds] < 60
		} {
			unset creds
		}

		if {![info exists creds]} { # Attempt to find some credentials laying around
			# Environment variables <<<
			if {
				[info exists env(AWS_ACCESS_KEY_ID)] &&
				[info exists env(AWS_SECRET_ACCESS_KEY)]
			} {
				dict set creds access_key		$env(AWS_ACCESS_KEY_ID)
				dict set creds secret			$env(AWS_SECRET_ACCESS_KEY)
				if {[info exists env(AWS_SESSION_TOKEN)]} {
					dict set creds token		$env(AWS_SESSION_TOKEN)
				}
				dict set creds source			env
				_debug {log debug "Found credentials: env"}
				return $creds
			}

			# Environment variables >>>
			# User creds: ~/.aws/credentials <<<
			set credfile	[file join $::env(HOME) .aws/credentials]
			if {[file readable $credfile]} {
				package require inifile
				set ini	[::ini::open $credfile]
				try {
					dict set creds access_key	[::ini::value $ini default aws_access_key_id]
					dict set creds secret		[::ini::value $ini default aws_secret_access_key]
					dict set creds token		""
					dict set creds source		user
					_debug {log debug "Found credentials: user"}
				} on ok {} {
					return $creds
				} finally {
					::ini::close $ini
				}
			}

			# User creds: ~/.aws/credentials >>>
			# Instance role creds <<<
			try {
				instance_role_creds
			} on ok role_creds {
				dict set creds access_key		[json get $role_creds AccessKeyId]
				dict set creds secret			[json get $role_creds SecretAccessKey]
				dict set creds token			[json get $role_creds Token]
				dict set creds expires			[json get $role_creds expires_sec]
				dict set creds source			instance_role
				_debug {log debug "Found credentials: instance_role"}
				return $creds
			} on error {} {}
			# Instance role creds >>>

			throw {AWS NO_CREDENTIALS} "No credentials were supplied or could be found"
		}

		set creds
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
	proc instance_role_creds {} { #<<<
		global env
		variable cached_role_creds

		if {
			![info exists cached_role_creds] ||
			[json get $cached_role_creds expires_sec] - [clock seconds] < 60
		} {
			#set cached_role_creds	[_metadata meta-data/identity-credentials/ec2/security-credentials/ec2-instance]
			if {[info exists env(AWS_CONTAINER_CREDENTIALS_RELATIVE_URI)]} {
				set cached_role_creds	[_metadata_req http://169.254.170.2$env(AWS_CONTAINER_CREDENTIALS_RELATIVE_URI)]
			} else {
				set role				[_metadata meta-data/iam/security-credentials]
				set cached_role_creds	[_metadata meta-data/iam/security-credentials/$role]
			}

			json set cached_role_creds expires_sec	[clock scan [json get $cached_role_creds Expiration] -timezone :UTC -format {%Y-%m-%dT%H:%M:%SZ}]
		}
		set cached_role_creds
	}

	#>>>

		proc _metadata_req url { #<<<
			rl_http instvar h GET $url -stats_cx AWS -timeout 1
			if {[$h code] != 200} {
				throw [list AWS [$h code]] [$h body]
			}
			$h body
		}

		#>>>
		proc _metadata path { #<<<
			global env

			if {[identify] eq "ECS"} {
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
			} else {
				set base	http://169.254.169.254/latest
			}
			_metadata_req $base/[string trimleft $path /]
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

		rl_http instvar h GET $base/[string trimleft $path /] -stats_cx AWS
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

	proc identify {} { # Attempt to identify the AWS platform: EC2, Lambda, ECS, or none - not on AWS <<<
		_cache identify {
			global env

			if {
				[file readable /sys/devices/virtual/dmi/id/sys_vendor] &&
				[string trim [readfile /sys/devices/virtual/dmi/id/sys_vendor]] eq "Amazon EC2"
			} {
				return EC2
			}

			if {[info exists env(LAMBDA_TASK_ROOT)]} {
				return Lambda
			}

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
	proc local_ipv4 {}			{_metadata meta-data/local-ipv4}

	if 0 {
	# Many newer AWS services' APIs follow this pattern:
	proc build_action_api args { #<<<
		parse_args $args {
			-scheme			{-default http}
			-service		{-required}
			-endpoint		{}
			-target_service	{-# {If specified, override $service in x-amz-target header}}
			-accessor		{-# {If specified, override s/-/_/g($service) as the ensemble cname}}
			-actions		{-required}
		}

		if {![info exists target_service]} {
			set target_service	$service
		}

		if {![info exists accessor]} {
			set accessor	[string map {- _} $service]
		}

		if {![info exists endpoint]} {
			set endpoint	$service
		}

		namespace eval ::aws::$accessor [string map [list \
			%scheme%			[list $scheme] \
			%service%			[list $endpoint] \
			%sig_service%		[list $service] \
			%target_service%	[list $target_service] \
		] {
			namespace export *
			namespace ensemble create -prefixes no
			namespace path {
				::parse_args
			}

			proc log args {tailcall aws::helpers::log {*}$args}
			proc req args { #<<<
				parse_args $args {
					-region		{-default us-east-1}
					-params		{-required}
					-action		{-required}
				}

				_aws_req POST %service% / \
					-sig_service	%sig_service% \
					-scheme			%scheme% \
					-region			$region \
					-body			[encoding convertto utf-8 $params] \
					-content_type	application/x-amz-json-1.1 \
					-headers		[list x-amz-target %target_service%.$action]
			}

			#>>>
		}]

		foreach action $actions {
			# FooBarBaz -> foo_bar_baz
			proc ::aws::${accessor}::[string tolower [join [regexp -all -inline {[A-Z][a-z]+} $action] _]] args [string map [list \
				%action% [list $action] \
			] {
				parse_args $args {
					-region		{-default us-east-1}
					-params		{-default {{}} -# {JSON doc containing the request parameters}}
				}

				req -region $region -action %action% -params $params
			}]
		}
	}

	#>>>
	}

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
			variable ei
			variable protocol
			variable apiVersion
			namespace current
		}]

		upvar 1 ei ei  protocol protocol  {*}[concat {*}[lmap uv $upvars {list $uv _a_$uv}]]

		set endpoint_info	[{*}$ei $region]
		#puts stderr "endpoint_info:\n\t[join [lmap {k v} $endpoint_info {format {%20s: %s} $k $v}] \n\t]"
		set uri_map_out	{}
		foreach {pat arg} $uri_map {
			lappend uri_map_out	"{$pat}" [if {[info exists _a_$arg]} {
				urlencode rfc_urlencode -part path -- [set _a_$arg]
			}]
		}

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
		foreach {name arg} $query_map {
			if {[info exists _a_$arg]} {
				lappend query $name [set _a_$arg]
			}
		}
		#puts stderr "query_map ($query_map), query: ($query)"

		if {$protocol eq "query" && [info exists ${service_ns}::apiVersion]} {
			# Inject the Version param
			lappend query Version [set ${service_ns}::apiVersion]
		}

		if {$content_type eq "application/x-www-form-urlencoded; charset=utf-8"} {
			set body	[join [lmap {k v} $query {
				format %s=%s [urlencode rfc_urlencode -- $k] [urlencode rfc_urlencode -- $v]
			}] &]
			set query	{}
		} elseif {$payload ne ""} {
			if {[info exists _a_$payload]} {
				if {$xml_input eq {}} {
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
						set body	[$root asXML]
					} finally {
						$doc delete
					}
				}
			} else {
				set body	{}
			}
		} elseif {$template ne {}} {
			set body	[encoding convertto utf-8 [uplevel 1 [list json template $template]]]
		} else {
			set body	{}
		}

		#set scheme	[lindex [dict get $endpoint_info protocols] end]
		set scheme	[lindex [dict get $endpoint_info protocols] 0]
		if {[string tolower $scheme] eq "https" && [dict exists $endpoint_info sslCommonName]} {
			set hostname	[dict get $endpoint_info sslCommonName]
		} else {
			set hostname	[dict get $endpoint_info hostname]
		}

		try {
			#puts stderr "Requesting $method $hostname, path: ($path)($uri_map_out) -> ([string map $uri_map_out $path]), query: ($query), headers: ($headers), body:\n$body"
			_aws_req $method $hostname [string map $uri_map_out $path] \
				-params				$query \
				-sig_service		$signingName \
				-scheme				$scheme \
				-region				[dict get $endpoint_info region] \
				-credential_scope	[dict get $endpoint_info credentialScope region] \
				-version			[lindex [dict get $endpoint_info signatureVersions] end] \
				-body				$body \
				-content_type		$content_type \
				-headers			$headers \
				-expecting_status	$expected_status \
				-response_headers	response_headers \
				-status				status
		} on ok body {
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
					if {[json size $tmp] > 0} {
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
				if {$protocol in {query rest-xml} && $body ne ""} {
					# TODO: check content-type xml?
					package require tdom
					# Strip the xmlns
					set doc [dom parse $body]
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
		set doc	[dom parse $xml]
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
		set eof		[string first \u1A $bytes]
		set reconstructed [string map [list \
			%p		" args \{parse_args \$args \{-region \{-default {}\} -requestid -alias " \
			%r		";_service_req -r \$region " \
			{*}$custom_maps \
		] [encoding convertfrom utf-8 [zlib gunzip [string range $bytes $eof+1 end]]]]
		#puts stderr "reconstructed:\n$reconstructed"
		eval $reconstructed
	}

	#>>>
}

# Hook into the tclreadline tab completion
namespace eval ::tclreadline {
	proc complete(aws) {text start end line pos mod} {
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
}

# vim: ft=tcl foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
