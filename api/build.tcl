# TODO:
# - Wire up XML response error handling
# - EC2 protocol (and service)
# - Implement paginators
# - Clean up this horrible mess

if {[file exists /here/api]} {
	tcl::tm::path add /here/api
}
set aws_ver	[package require aws 2]

package require rl_json
package require parse_args
package require chantricks

namespace import rl_json::*
namespace import parse_args::*
namespace import chantricks::*

proc colour args { #<<<
	package require cflib

	parse_args $args {
		colours	{-required}
		text	{-required}
	}

	string cat [cflib::c {*}$colours] $text [cflib::c norm]
}

#>>>
proc highlight args { #<<<
	parse_args $args {
		-regexp		{}
		text		{-required}
	}

	if {[info exists regexp]} {
		puts stderr [colour {bright green} "matching [list $regexp]"]
		set text	[regsub -all -line $regexp $text [colour {bright red} {\0}]]
	}
	set text
}

#>>>
proc compile_input args { #<<<
	parse_args $args {
		-argname		{}
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
				set name	[join [lmap e [regexp -all -inline {[A-Za-z][a-z]+} $camel_name] {string tolower $e}] _]
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
proc compile_output args { #<<<
	parse_args $args {
		-protocol		{-required}
		-params			{-alias}
		-status_map		{-alias}
		-header_map		{-alias}
		-def			{-required}
		-shape			{-required}
		-errors			{-default {}}
		-reponses		{-alias}
	}

	set output	[json extract $def shapes $shape]

	#puts stderr "compile_output, type: [json pretty $output]"
	switch -- [json get $output type] {
		structure {
			set template_obj	{{}}
			json foreach {camel_name member_def} [json extract $output members] {
				if {[json exists $output payload] && $camel_name eq [json get $output payload]} continue

				if {[json exists $member_def location]} {
					set name	[join [lmap e [regexp -all -inline {[A-Za-z][a-z]+} $camel_name] {string tolower $e}] _]
					lappend params	-$name {-alias}

					switch -- [json get $member_def location] {
						headers {
							lappend header_map	[string tolower [json get $member_def locationName]]* $name
						}
						header {
							lappend header_map	[string tolower [json get $member_def locationName]] $name
						}
						statusCode {
							set status_map	$name
						}
						default {
							error "Unhandled location for $camel_name: ([json get $member_def location])"
						}
					}
				}
			}
		}
		string {
			set template_obj	"~S:$argname"
		}
		map {
			set template_obj	"~J:$argname"
		}
		list {
			set template_obj	"~J:$argname"
		}
		integer {
			set template_obj	"~N:$argname"
		}
		blob {
			set template_obj	"~S:$argname"
		}
		default {
			if {![json get $def shapes [json exists $output type]]} {
				error "Unhandled type \"[json get $input type]\""
			}
			set template_obj	[compile_output \
				-protocol	$protocol \
				-argname	$argname \
				-def		$def \
				-shape		[json get $input type] \
			]
		}
	}

	set template_obj
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

proc build_aws_services args { #<<<
	parse_args $args {
		-definitions	{-required -# {Directory containing the service definitions from botocore}}
		-prefix			{-default api_out -# {Where to write the service tms}}
		-services		{-default {} -# {Supply a list of services to only build those, default is to build all}}

		-ziplet			{-name output_mode -multi -default ziplet}
		-plain			{-name output_mode -multi}
	}

	file mkdir [file join $prefix aws]

	# TODO: lookup partition based on region matching [json get $partition regionRegex] ?
	set partition	[json extract [readfile $definitions/endpoints.json] partitions 0]
	set defaults	[json get $partition defaults]

	set by_protocol	{}
	foreach service_dir [glob -type d -tails -directory $definitions *] {
		set latest	[lindex [glob -type d -tails -directory [file join $definitions $service_dir] *] 0]
		if {$latest eq ""} {
			error "Couldn't resolve latest version of $service_dir"
		}
		set service_fn	[file join $definitions $service_dir $latest service-2.json]
		if {![file exists $service_fn]} {
			error "Couldn't read definition of $service_dir/$latest"
		}
		set service_def			[readfile $service_fn]
		set service_name_orig	[lindex [file split $service_dir] 0]
		set service_name		[string map {- _} $service_name_orig]

		if {[llength $services] > 0 && $service_name ni $services} continue

		#puts "dir $service_dir endpointprefix: [json get $service_def metadata endpointPrefix], exists: [json exists $partition services [json get $service_def metadata endpointPrefix]], protocol: [json get $service_def metadata protocol]"
		set metadata	[json extract $service_def metadata]
		json set service_def metadata service_name		[json string $service_name]
		json set service_def metadata service_name_orig	[json string $service_name_orig]
		dict lappend by_protocol [json get $service_def metadata protocol] $service_def
	}


	dict for {protocol services} $by_protocol {
		puts "$protocol:\n\t[join [lmap service $services {
			format {%30s: %s} [json get $service metadata service_name] [json get $service metadata serviceFullName]
		}] \n\t]"
	}

	foreach service_def [list {*}[dict get $by_protocol json] {*}[dict get $by_protocol rest-json] {*}[dict get $by_protocol query] {*}[dict get $by_protocol rest-xml]] {
		#puts "creating ::aws::[json get $service_def metadata service_name]"
		set protocol	[json get $service_def metadata protocol]
		set service_code	{namespace export *;namespace ensemble create -prefixes no;namespace path {::parse_args ::rl_json ::aws};variable endpoint_cache {};}

		set endpoint_info	[json get $partition defaults]
		if {[json exists $partition services [json get $service_def metadata endpointPrefix]]} {
			set endpoint_info	[dict merge $endpoint_info [json get $partition services [json get $service_def metadata endpointPrefix]]]
		}
		#puts "[json get $service_def metadata endpointPrefix]:\n\t[join [lmap {k v} $endpoint_info {
		#	if {$k eq "endpoints"} {
		#		format "%20s:\n\t\t%s" $k [join [lmap {epk epv} $v {
		#			format {%20s: (%s)} $epk $epv
		#		}] \n\t\t]
		#	} else {
		#		format {%20s: (%s)} $k $v
		#	}
		#}] \n\t]"

		append service_code [list variable protocol $protocol] \n
		append service_code	[list variable ei [list ::aws::_ei \
			::aws::[json get $service_def metadata service_name] \
			[json get $service_def metadata endpointPrefix] \
			[json get $partition defaults] \
			[json get $partition dnsSuffix] \
			[if {[json exists $partition services [json get $service_def metadata endpointPrefix]]} {
				json get $partition services [json get $service_def metadata endpointPrefix]
			}] \
		]] \n

		set responses	{}
		set exceptions	{}
		set def			$service_def
		json foreach {op opdef} [json extract $def operations] {
			try {
				set cmd	[join [lmap e [regexp -all -inline {[A-Za-z][a-z]+} $op] {string tolower $e}] _]
				#puts stderr "[json get $def metadata service_name]: op: ($op) -> cmd: ($cmd), opdef: [json pretty $opdef]"

				unset -nocomplain w
				set static		{}
				set c			{application/x-amz-json-1.1}
				set params		{}
				set u			{}
				set hm			{}
				set q			{}
				if {$protocol eq "query"} {
					lappend q		Action _a
					lappend static	[list set _a $op]
				}

				set b			{}
				if {[json exists $opdef input]} {
					set t	[compile_input \
						-protocol	$protocol \
						-params		params \
						-uri_map	u \
						-query_map	q \
						-header_map	hm \
						-payload	b \
						-shapes		[json extract $def shapes] \
						-shape		[json get $opdef input shape]]

					if {$protocol eq "rest-xml"} {
						set x	[compile_xml_input \
							-shapes	[json extract $def shapes] \
							-input	[json extract $opdef input]]
						set t	{}
					}
				} else {
					set t	{}
				}

				set sm		{}
				set o		{}
				if {[json exists $opdef output]} {
					if {[json exists $opdef errors]} {
						set errors	[json lmap e [json extract $opdef errors] {json get $e shape}]
					} else {
						set errors	{}
					}

					if {$protocol in {query rest-xml}} {
						if {[json exists $opdef output resultWrapper]} {
							set resultWrapper	[json get $opdef output resultWrapper]
						} else {
							# Could be because the action returns nothing in the body, or that the context node is to be the root of the response document
							#puts stderr "No resultWrapper for [json get $def metadata service_name] $op in [json pretty $opdef]"
							set resultWrapper	{}
						}
						foreach exception $errors {
							set rshape	[json extract $def shapes $exception]
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
								%SVC%	[list [string toupper [json get $def metadata service_name]]] \
								%type%	[list $type] \
								%code%	[list $code] \
								%msg%	[list $msg] \
							] {throw {AWS %SVC% %type% %code%} %msg%}]
						}
						set response	[json get $opdef output shape]
						set rshape		[json extract $def shapes $response]
						set w			$resultWrapper
						set fetchlist	{}
						set template	[compile_xml_transforms \
							-shape		$response \
							-shapes		[json extract $def shapes] \
							-fetchlist	fetchlist]

						if {[llength $fetchlist]} {
							set R	$response
							dict set responses $response [list $fetchlist $template]
						}
					}

					compile_output \
						-protocol	$protocol \
						-params		params \
						-status_map	sm \
						-header_map	o \
						-def		$def \
						-shape		[json get $opdef output shape]
				}

				if {[json exists $def metadata signingName]} {
					set s	[json get $def metadata signingName]
				} else {
					set s	[json get $def metadata service_name_orig]
				}

				if {$protocol eq "json" && [json exists $def metadata targetPrefix]} {
					set h	[list x-amz-target [json get $def metadata targetPrefix].$op]
				} else {
					set h	{}
				}

				if {[json exists $opdef http responseCode]} {
					set e	[json get $opdef http responseCode]
				} else {
					set e	200
				}

				set m		[json get $opdef http method]
				set p		[json get $opdef http requestUri]

				if {$protocol eq "query" && $m eq "POST"} {
					set c	{application/x-www-form-urlencoded; charset=utf-8}
					set t	{}
				}

				set service_args	{}
				set defaults {
					b		{}
					c		application/x-amz-json-1.1
					e		200
					h		{}
					hm		{}
					m		POST
					o		{}
					p		/
					q		{}
					R		{}
					sm		{}
					t		{}
					u		{}
					w		{}
					x		{}
				}
				foreach v {
					b
					c
					e
					h
					hm
					m
					o
					p
					q
					R
					s
					sm
					t
					u
					w
					x
				} {
					if {[info exists $v] && (![dict exists $defaults $v] || [set $v] ne [dict get $defaults $v])} {
						lappend service_args -$v [set $v]
					}
				}

				if {[llength $static] != 0} {set static ";[join $static ";"]"}
				append service_code "proc [list $cmd]%p$params\}$static%r$service_args\}" \n
			} on error {errmsg options} {
				set prefix	"Error compiling service [json get $service_def metadata service_name].$op:"
				set errmsg	$prefix\n$errmsg
				dict set options -errorinfo $prefix\n[dict get $options -errorinfo]
				return -options $options $errmsg
			}
		}

		# Write out the response handlers, if any (XML protocols)
		if {[dict size $exceptions] > 0} {
			append service_code "namespace eval _errors \{" \n
		}
		dict for {exception handler} $exceptions {
			append service_code "proc [list $exception] b [list $handler]" \n
		}
		if {[dict size $exceptions] > 0} {
			append service_code "\}" \n
		}
		if {[dict size $responses] > 0} {
			append service_code "variable responses {\n[join [lmap {k v} $responses {format "%s\t%s" [list $k] [list $v]}] \n]\n}" \n
		}
		if {
			[json get $service_def metadata protocol] eq "query" &&
			[json exists $service_def metadata apiVersion]
		} {
			append service_code "variable apiVersion [list [json get $service_def metadata apiVersion]]" \n
		}

		set service_code "namespace eval [list ::aws::[json get $service_def metadata service_name]] {$service_code}"
		#variable ::aws::[json get $service_def metadata service_name]::def $service_def
		set zipped		[zlib gzip [encoding convertto utf-8 $service_code] -level 9]
		set ziplet		[encoding convertto utf-8 {package require aws 2;::aws::_load}]\u1A$zipped
		puts stderr "[json get $service_def metadata service_name] ([string length $service_code] chars, [string length $zipped] gzipped bytes):"
		incr total_raw	[string length $service_code]
		incr total_ziplet		[string length $ziplet]
		if {[json get $service_def metadata service_name] in {}} {
			puts stderr [highlight -regexp {^proc (create_bucket|list_buckets|delete_bucket)%.*$} $service_code]
		}
		set aws_ver	[package require aws 2]
		switch -exact -- $output_mode {
			ziplet {
				writebin [file join $prefix aws/[json get $service_def metadata service_name]-$aws_ver.tm] $ziplet
			}
			plain {
				writefile [file join $prefix aws/[json get $service_def metadata service_name]-$aws_ver.tm] $service_code
			}
			default {
				error "Unknown output mode \"$output_mode\""
			}
		}
	}
	puts "total_raw: $total_raw"
	puts "total_ziplet: $total_ziplet"
}

#>>>

build_aws_services {*}$argv

if 1 return


set test_services	{}
#lappend test_services lambda
#lappend test_services ecr
lappend test_services secretsmanager
#lappend test_services appconfig
#lappend test_services dynamodb
#lappend test_services sqs
#lappend test_services	s3

foreach service $test_services {
	puts stderr "source $service: [timerate {
		source [file join $prefix aws/$service-$aws_ver.tm]
	} 1 1]"
}
if {"ecr" in $test_services} {
	puts stderr "first:  [timerate {aws ecr describe_repositories} 1 1]"
	puts stderr "second: [timerate {aws ecr describe_repositories} 1 1]"
}
if {"lambda" in $test_services} {
	puts stderr "list-functions: [json pretty [aws lambda list_functions -function_version ALL]]"
	puts stderr "get-function: [json pretty [aws lambda get_function -function_name veryLayeredTcl]]"
	puts stderr "functions:\n\t[join [json lmap f [json extract [aws lambda list_functions] Functions] {json get $f FunctionName}] \n\t]"
	#       veryLayeredTcl
	#       testTclLambda
	#       Test_Lambda_1
	#       layeredTcl
	set payload [aws lambda invoke \
		-function_name		veryLayeredTcl \
		-log_type			Tail \
		-status_code		status \
		-function_error		err \
		-log_result			log \
		-executed_version	exec_ver \
		-requestid			requestid \
		-payload [encoding convertto utf-8 [json template {
			{
				"hello": "worldはfoo"
			}
		}]] \
	]
	foreach v {status err log exec_ver payload requestid} {
		if {[info exists $v]} {
			if {$v eq "log"} {
				set val	\n[encoding convertfrom utf-8 [binary decode base64 [set $v]]]
			} else {
				set val	[set $v]
			}
			puts [format {%20s: %s} $v $val]
		}
	}
}

if {"secretsmanager" in $test_services} {
	puts stderr "secretsmanager get_random_password: ([aws secretsmanager get_random_password -exclude_punctuation])"
}
foreach service $test_services {
	puts "$service:\n\t[join [lmap e [lsort -dictionary [info commands ::aws::${service}::*]] {namespace tail $e}] \n\t]"
}

if {"sqs" in $test_services} {
	puts stderr "sqs list_queues: [set res [aws sqs list_queues -region af-south-1 -queue_name_prefix Test]]"
	puts stderr [json pretty $res]
	if 0 {
	puts stderr "nodename: [[xml root $res] nodeName]"
	#[xml root $res] removeAttribute xmlns
	xml with res {
		puts stderr "res: $res ([$res asXML])"
		$res removeAttribute xmlns
		puts stderr "res after: $res ([$res asXML])"
	}
	puts stderr "outer, res exists: [info exists res]"
	#puts stderr "outer: $res"
	#[xml root $res] removeAttribute xmlns
	#set res	[[xml root $res] asXML]
	puts stderr "get queues: [timerate {
		puts stderr "queues:\n\t[join [lmap node [xml get $res /*/ListQueuesResult/QueueUrl] {format %s(%s) $node [$node text]}] \n\t]"
	} 1 1]"
	#puts stderr "res: ($res)"
	puts stderr "lmap queues:\n\t[join [xml lmap n $res /*/ListQueuesResult/QueueUrl {$n text}] \n\t]"
	}
}

if {"s3" in $test_services} {
	puts "s3 create_bucket: [aws s3 create_bucket -region af-south-1 -bucket aws-tcl-test -create_bucket_configuration [json template {
		{
			"LocationConstraint": "af-south-1"
		}
	}]]"
	puts "s3 list_buckets: [json pretty [aws s3 list_buckets -region af-south-1]]"
	puts "s3 delete_bucket: [aws s3 delete_bucket -region af-south-1 -bucket aws-tcl-test]"
}

# vim: ft=tcl foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
