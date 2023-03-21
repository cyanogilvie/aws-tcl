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
		set ini	[::ini::open [file join $::env(HOME) .aws/config] r]
		if {[info exists ::env(AWS_PROFILE)]} {
			set section	"profile $::env(AWS_PROFILE)"
		} else {
			set section	default
		}
		try {
			::ini::value $ini $section region
		} finally {
			::ini::close $ini
			unset -nocomplain ini
		}
	} else {
		return -level 0 us-east-1
	}]

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
				set canonical_uri		/
				set canonical_uri_sig	/
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
				set canonical_uri_sig	/[join [lmap e $n_urlv {
					if {$sig_service eq "s3"} {
						apply $aws_encode $e
					} else {
						# Services other than S3 have to have the path elements encoded twice according to the documentation, but not the test vectors...
						apply $aws_encode [apply $aws_encode $e]
						#apply $aws_encode $e
					}
				}] /]
				set canonical_uri	/[join [lmap e $n_urlv {
					apply $aws_encode $e
				}] /]
				if {$sig_service eq "s3" && [string index $path end] eq "/" && [string index $canonical_uri end] ne "/"} {
					append canonical_uri		/
					append canonical_uri_sig	/
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
					puts stderr "setting x-amz-content-sha256"
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

			foreach {k v} $t_headers {
				if {$k ne "x-amz-content-sha256"} continue
				set hashed_payload $v
			}
			if {![info exists hashed_payload]} {
				set hashed_payload	[hash $algorithm $body]
			}

			set canonical_request	"[string toupper $method]\n$canonical_uri_sig\n$canonical_query_string\n$canonical_headers\n$signed_headers\n$hashed_payload"
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
					set ini	[::ini::open $credfile r]
					if {[info exists ::env(AWS_PROFILE)]} {
						set section	$::env(AWS_PROFILE)
					} else {
						set section	default
					}
					try {
						dict set creds access_key	[::ini::value $ini $section aws_access_key_id]
						dict set creds secret		[::ini::value $ini $section aws_secret_access_key]
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
						set base	$env($v)
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
			if {$path eq "/"} {
				_metadata_req $base
			} else {
				_metadata_req $base/[string trimleft $path /]
			}
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
			if {![info exists ei]} {variable ei}
			variable protocol
			variable apiVersion
			namespace current
		}]

		upvar 1 ei ei  protocol protocol  response_headers response_headers  {*}[concat {*}[lmap uv $upvars {list $uv _a_$uv}]]

		set endpoint_info	[{*}$ei $region]
		#puts stderr "endpoint_info:\n\t[join [lmap {k v} $endpoint_info {format {%20s: %s} $k $v}] \n\t]"
		set uri_map_out	{}
		foreach {pat arg} $uri_map {
			set rep	[if {[info exists _a_$arg]} {
				set _a_$arg
			}]
			set repe	[urlencode rfc_urlencode -part path -- $rep]
			lappend uri_map_out	"{$pat}" $repe "{$pat+}" $rep
		}
		puts stderr "uri_map_out: ($uri_map_out)"

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
			if {[json length $body] == 0} {
				set body	""
				set content_type	""
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
			%p		" args \{parse_args \$args \{-region \{-default {}\} -requestid -alias -response_headers -alias " \
			%r		";_service_req -r \$region " \
			{*}$custom_maps \
		] [encoding convertfrom utf-8 [zlib gunzip [string range $bytes $eof+1 end]]]]
		#puts stderr "reconstructed:\n$reconstructed"
		eval $reconstructed
	}

	#>>>
	proc from_camel str { # UseFIPS -> use_fips, WriteGetObjectResult -> write_get_object_result <<<
		join [lmap {- caps title} [regexp -all -inline {([A-Z]+(?=[A-Z]|$))|([A-Za-z][a-z]+)} $str] {
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
	proc _load_ziplet {} { #<<<
		set file	[uplevel 1 {info script}]
		set h		[open $file rb]
		set bytes	[try {read $h} finally {close $h}]
		set eof		[string first \u1A $bytes]
		set source	[encoding convertfrom utf-8 [zlib gunzip [string range $bytes $eof+1 end]]]
		uplevel #0 $source
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
		namespace path {::parse_args ::rl_json}

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
			if {![regexp {^arn:([^:]*):([^:]*):([^:]*):([^:]*):(?:([^:/]*)[:/])?(.*)$} $arn - partition service region accountid resource_type tail]} {
				error "Cannot parse arn: \"$arn\""
			}
			if {$resource_type ne ""} {
				set resource_ids	[list $resource_type]
			} else {
				set resource_ids	{}
			}
			lappend resource_ids	{*}[split $tail :/]
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
			#puts stderr "aws.partition service: ($service), region: ($region)"
			#if {$region eq "aws-global"} {set region us-east-1}
			package require aws::endpoints
			json foreach partition [json extract $::aws::endpoints partitions] {
				if {[json exists $partition services $service endpoints $region]} {
					json set partition name [json get $partition partition]
					return $partition
				}
			}
			#puts stderr "Could not find partition for ($region), returning null"
			return null
			#error "No partition for region \"$region\""
		}

		#>>>
		proc getAttr {doc key} { #<<<
			if {[json isnull $doc]} {return null}
			if {[regexp {^(.*)\[([0-9]+)\]$} $key - base idx]} {
				#if {![json exists $doc $base $idx]} {return null}
				json get $doc $base $idx
			} else {
				#if {![json exists $doc $key]} {return null}
				json get $doc $key
			}
		}

		#>>>
		proc isValidHostLabel {str allowdots} { #<<<
			#puts stderr "isValidHostLabel ($str), $allowdots"
			if {$allowdots} {
				regexp {^[a-zA-Z0-9.-]+$} $str
			} else {
				regexp {^[a-zA-Z0-9-]+$} $str
			}
		}

		#>>>
		proc parseURL uri { #<<<
			try {
			#puts stderr "aws::_fn::parseURL ($uri)"
			package require reuri 0.2.6
			set parts	[reuri::uri get $uri]
			dict set parts scheme	[reuri::uri get $uri scheme]
			dict set parts host		[reuri::uri get $uri host]
			dict set parts hosttype	[reuri::uri get $uri hosttype]
			dict set parts path		[reuri::uri get $uri path {}]
			if {[reuri::uri exists $uri port]} {
				dict append parts host :[reuri::uri get $uri port]
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
		proc substring {str idx len flag} { #<<<
			# TODO: figure out what boolean $flag means
			#puts stderr "::aws::_fn::substring str: ($str), idx: ($idx), len: ($len), flag: ($flag)"
			string range $str $idx [expr {$idx+$len-1}]
		}

		#>>>
		proc uriEncode str { #<<<
			package require reuri
			reuri::uri encode path $str
		}

		#>>>
		proc _e args { #<<<
			parse_args $args {
				msg			{-required}
				istemplate	{-required}
				lookup		{}
			}
			if {[info exists lookup]} {
				set msg	[lindex $lookup $msg]
			}
			if {$istemplate} {
				throw terr $msg
			} else {
				error $msg
			}
		}

		#>>>
		proc _r args { #<<<
			parse_args $args {
				ep		{-required}
				lookup	{}
			}

			if {[info exists lookup]} {
				set ep	[lindex $lookup $ep]
			}
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
				if {[json valid $res] && [json isnull $res]} {
					return 0
				}
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
				switch -exact [json get $details type] {
					String {}
					Boolean {lappend settings -validate {string is boolean -strict}}
					default {error "Unhandled endpoint rules param type: \"[json get $details type]\""}
				}
				lappend argspec $name $settings
				lappend copy_to_cx $camel_name $camel_name
			}
		}
		# Add the endpoint context input params to argspec and input wiring >>>

		set body	""
		append body	{variable service_def} \n
		append body	[list set cxparams	$cxparams] \n
		append body	"parse_args \$args [list $argspec] params\n"
		append body {puts stderr "params: ($params)"} \n
		append body {puts stderr "cxparams: ($cxparams)"} \n
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
		append body {puts stderr "computed endpoint: [json pretty $endpoint]"} \n
		append body	[list puts stderr "Would call [namespace tail [namespace current]]->$op: [json pretty $opdef]"] \n
		if {[json exists $opdef input shape]} {
			append body [list puts stderr "Input shape: [json pretty [json extract $service_def shapes [json get $opdef input shape]]]"]
		}
				set params		{}
				set u			{}
				set hm			{}
				set q			{}
				set b			{}
				set x			{}
				if {[json exists $opdef input]} {
					aws::build::compile_input \
						-argname_transform	{} \
						-protocol	[json get $service_def metadata protocol] \
						-params		params \
						-uri_map	u \
						-query_map	q \
						-header_map	hm \
						-payload	b \
						-shapes		[json extract $service_def shapes] \
						-shape		[json get $opdef input shape]

					set x	[aws::build::compile_xml_input \
						-shapes	[json extract $service_def shapes] \
						-input	[json extract $opdef input]]
				}
		if {[json exists $opdef output shape]} {
			set outshape	[json extract $service_def shapes [json get $opdef output shape]]
			puts stderr "Output shape: [json pretty $outshape]"
					if {[json exists $opdef errors]} {
						set errors	[json lmap e [json extract $opdef errors] {json get $e shape}]
					} else {
						set errors	{}
					}
						if {[json exists $opdef output resultWrapper]} {
							set resultWrapper	[json get $opdef output resultWrapper]
						} else {
							# Could be because the action returns nothing in the body, or that the context node is to be the root of the response document
							#puts stderr "No resultWrapper for [json get $def metadata service_name] $op in [json pretty $opdef]"
							set resultWrapper	{}
						}
						if {![info exists exceptions]} {
							set exceptions	{}
						}
						foreach exception $errors {
							set rshape	[json extract $service_def shapes $exception]
							if {[dict exists $exceptions $exception]} continue
							# TODO: strip html from [json get $rshape documentation]
							if {[json exists $rshape error code]} {
								set code	[json get $rshape error code]
							} else {
								set code	none
							}
							if {[json exists $rshape error senderFault]} {
								set type	[expr {[json get $rshape error senderFault] ? "Sender" : "Server"}]
							} else {
								set type	unknown
							}
							if {[json exists $rshape documentation]} {
								set msg		[json get $rshape documentation]
							} else {
								set msg		""
							}
							dict set exceptions $exception [string map [list \
								%SVC%	[list [string toupper [json get $service_def metadata service_name]]] \
								%type%	[list $type] \
								%code%	[list $code] \
								%msg%	[list $msg] \
							] {throw {AWS %SVC% %type% %code%} %msg%}]
						}
						set response	[json get $opdef output shape]
						set rshape		[json extract $service_def shapes $response]
						set w			$resultWrapper
						set fetchlist	{}
						set template	[aws::build::compile_xml_transforms \
							-shape		$response \
							-shapes		[json extract $service_def shapes] \
							-fetchlist	fetchlist]

						if {[llength $fetchlist]} {
							puts stderr "Response: ($response): fetchlist: ($fetchlist), template: ($template)"
							dict set responses $response [list $fetchlist $template]
						}
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
		] {
			package require reuri

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
				}

				set url		[json get $endpoint url]
				dict create \
					protocols				[list [reuri::uri get $url scheme http]] \
					hostname				[reuri::uri get $url host] \
					url						$url \
					region					[json get $endpoint _ region] \
					credentialScope			[json get $endpoint _ credentialScope] \
					signatureVersions		[list $sigver] \
					disableDoubleEncoding	[json get $authscheme disableDoubleEncoding]
			}] $endpoint]

			set path	[string trimright [reuri::uri get [json get $endpoint url] path {}] /]
			append path	%requestUri%
			dict with params {}		;# The unpacked key variables are accessed by the request procs through upvar
			::aws::_service_req \
				-s		[json get $endpoint properties authSchemes 0 signingName] \
				-m		%http_method% \
				-p		$path \
				-R		%response% \
				-e		%expect_status% \
				-b		%payload% \
				-hm		%header_map% \
				-q		%query_map% \
				-u		%uri_map% \
				-w		%resultWrapper% \
				-x		%xml_input%
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
					#puts stderr "matched attr syntax: base: ($base), attr: ($attr) ([set -)]"
					set subst	[json get [dict get $dict $base] $attr]
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
		#puts stderr "objecttemplate, object: ($object), dict keys: ([dict keys $dict])"
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
	namespace eval build {
		namespace path {::parse_args ::rl_json}
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
				puts stderr "compile_xml_transforms, type: ($type), path: ($path), payload exists? ([json exists $rshape payload]), location: ([if {[json exists $rshape location]} {json get $rshape location}])"

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
						if {[json exists $rshape member locationName]} {
							set elemname	[json get $rshape member locationName]
						} else {
							set elemname	$source
						}
						lappend fetchlist [list $nextkey [typekey $type] $source/$elemname $subfetchlist $valuetemplate]

						set template	"~J:$nextkey"
					}

					structure {
						set template	{{}}
						json foreach {name member} [json extract $rshape members] {
							puts stderr "structure member $name, location: ([if {[json exists $member location]} {json get $member location}])"
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
		proc compile_input args { #<<<
			parse_args $args {
				-argname		{}
				-argname_transform	{-default aws::from_camel}
				-protocol		{-required}
				-params			{-alias}
				-uri_map		{-alias}
				-query_map		{-alias}
				-header_map		{-alias}
				-payload		{-alias}
				-shapes			{-required}
				-shape			{-required}
			}

			#puts stderr "compile_input, argname: ([if {[info exists argname]} {set argname}]), shape: ($shape)"
			set input	[json extract $shapes $shape]
			set type	[resolve_shape_type $shapes $shape]

			#puts stderr "compile_input, type: [json pretty $input]"
			switch -- $type {
				structure {
					# Only unfold the top level structure into params, just take sub-structures as json
					if {[info exists argname]} {
						return [json string "~J:$argname"]
					}

					set template_obj	{{}}
					json foreach {camel_name member_def} [json extract $input members] {
						if {$argname_transform eq ""} {
							set name	$camel_name
						} else {
							set name	[{*}$argname_transform $camel_name]
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
									lappend query_map	$locationName $name
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
									-protocol	$protocol \
									-argname	$name \
									-argname_transform	$argname_transform \
									-params		params \
									-uri_map	uri_map \
									-query_map	query_map \
									-header_map	header_map \
									-payload	payload \
									-shapes		$shapes \
									-shape		[json get $member_def shape] \
								]
							}
						} elseif {$protocol eq "query"} {
							lappend query_map $locationName $name
						} else {
							error "Unhandled protocol: ($protocol)"
						}
					}
				}
				timestamp -
				character -
				string {
					set template_obj	[json string "~S:$argname"]
				}
				map {
					set template_obj	[json string "~J:$argname"]
				}
				list {
					set template_obj	[json string "~J:$argname"]
				}
				integer -
				long -
				float -
				double {
					set template_obj	[json string "~N:$argname"]
				}
				boolean {
					set template_obj	[json string "~B:$argname"]
				}
				blob {
					set template_obj	[json string "~S:$argname"]
				}
				default {
					error "Unhandled type \"[json get $input type]\""
					if {![json exists $shapes [json get $input type]]} {
						error "Unhandled type \"[json get $input type]\""
					}
					set template_obj	[compile_input \
						-protocol	$protocol \
						-argname	$argname \
						-argname_transform	$argname_transform \
						-params		params \
						-uri_map	uri_map \
						-query_map	query_map \
						-header_map	header_map \
						-payload	payload \
						-shapes		$shapes \
						-shape		[json get $input type] \
					]
				}
			}

			if {[json exists $input payload]} {
				set payload	[join [lmap e [regexp -all -inline {[A-Za-z][a-z]+} [json get $input payload]] {string tolower $e}] _]
			}

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
