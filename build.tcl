# TODO:
# - Wire up XML response error handling
# - EC2 protocol (and service)
# - Implement paginators
# - Clean up this horrible mess

#if {[file exists /here/api]} {
#	tcl::tm::path add /here/api
#}
tcl::tm::path add [file join [file dirname [file normalize [info script]]] tm]
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

	if {$shape eq "GetObjectOutput"} {
		puts stderr "compile_output $shape, type: [json pretty $output]"
	}
	switch -- [json get $output type] {
		structure {
			set template_obj	{{}}
			json foreach {camel_name member_def} [json extract $output members] {
				if {[json exists $output payload] && $camel_name eq [json get $output payload]} continue

				if {$shape eq "GetObjectOutput"} {
					if {$camel_name eq "Body"} {
						puts stderr "Body: [resolve_shape_type [json extract $def shapes] $camel_name]"
					} else {
						puts stderr "camel_name: ($camel_name)"
					}
				}
				if {[json exists $member_def location]} {
					set name	[aws from_camel $camel_name]
					lappend params	-$name -alias

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

# Endpoint rules compilation <<<
proc extract_leaves endpoint_rules { # Pre-scan for duplicate leaves and errors <<<
	set leaves	{}
	set errors	{}
	set paths	[lmap e [json keys $endpoint_rules] {list $e}]
	set next	{}

	while {[llength $paths]} {
		foreach path $paths {
			switch -exact -- [lindex $path end] {
				endpoint {
					dict incr leaves [json normalize [json extract $endpoint_rules {*}$path]] 1
				}
				error {
					dict incr errors [json get $endpoint_rules {*}$path] 1
				}
			}

			switch -exact -- [json type $endpoint_rules {*}$path] {
				object {
					lappend next	{*}[lmap e [json keys $endpoint_rules {*}$path] {list {*}$path $e}]
				}
				array {
					set len	[json length $endpoint_rules {*}$path]
					for {set i 0} {$i < $len} {incr i} {
						lappend next	[list {*}$path $i]
					}
				}
			}
		}
		set paths	$next
		set next	{}
	}

	set i	-1
	set leaves	[dict map {v count} $leaves {if {$count < 2} continue; incr i}]
	set i	-1
	set errors	[dict map {v count} $errors {if {$count < 2} continue; incr i}]

	list $leaves $errors
}

# Pre-scan for duplicate leaves and errors >>>
proc compile_arg {arg inexpr} { #<<<
	upvar 1 service service

	try {
		switch -exact -- [json type $arg] {
			string				{
				switch -regexp -matchvar m -- [json get $arg] {
					{^{([^#]+)#(.*)}$} {
						lassign $m - base key
						return -level 0 "\[getAttr \$p($base) [list $key]\]"
					}
					{^{(.*)}$} {
						return -level 0 \$p([lindex $m 1])
					}
					default {
						if {$inexpr} {
							return -level 0 "{[json get $arg]}"
						} else {
							list [json get $arg]
						}
					}
				}
			}
			boolean	- number	{json get $arg}
			null				{error "Tried to compile arg with null value"}
			object {
				if {[json exists $arg ref]} {
					return "\$p([json get $arg ref])"
				} elseif {[json exists $arg fn]} {
					unset -nocomplain cexpr cmd
					switch -exact -- [json get $arg fn] {
						booleanEquals {
							set lhs	[compile_arg [json extract $arg argv 0] 1]
							set rhs	[compile_arg [json extract $arg argv 1] 1]
							if {[json type $arg argv 1] eq "boolean"} {
								if {[json get $arg argv 1]} {
									set cexpr aws_b($lhs)
								} else {
									set cexpr !aws_b($lhs)
								}
							} else {
								set cexpr aws_b($lhs)==aws_b($rhs)
							}
						}
						isSet {
							if {[json length $arg argv] != 1} {
								error "Condition fn isSet with bad argv length: [json length $arg argv]"
							}
							if {[json exists $arg argv 0 ref]} {
								set cexpr "\[info exists p([json get $arg argv 0 ref])\]"
							} elseif {[json exists $arg argv 0 fn]} {
								if {[json get $arg argv 0 fn] eq "getAttr"} {
									set tmp	[compile_arg [json extract $arg argv 0 argv 1] 0]
									# Accomodate expression debug decoration
									switch -regexp -matchvar m -- $tmp {
										{^\[::tcl::mathfunc::track_term (.*) } {set tmp [lindex $m 1]}
									}
									set path	[string map "\# { }" [lindex $tmp 0]]
									regsub -all {\[([0-9]+)\]} $path { \1} path
									#puts "([compile_arg [json extract $arg argv 0 argv 1] 0]) -> ($path)"
									set cexpr	"\[json exists [compile_arg [json extract $arg argv 0 argv 0] 0] $path\]"
								} else {
									set cmd	[string range [compile_arg [json extract $arg argv 0] 0] 1 end-1]	;# Strip off []
									set cexpr "(!\[catch [list $cmd] _r\]&&\[json valid \$_r\]&&!\[json isnull \$_r\])"
									#set cexpr "!\[catch [list $cmd] _r\]"
								}
							} else {
								error "Unhandled isSet case, argv: [json extract $arg argv]"
							}
						}
						not {
							if {[json length $arg argv] != 1} {
								error "Condition fn not with bad argv length: [json length $arg argv]"
							}
							set cexpr !([compile_arg [json extract $arg argv 0] 1])
						}
						stringEquals {
							set a	[compile_arg [json extract $arg argv 0] 1]
							set b	[compile_arg [json extract $arg argv 1] 1]
							foreach v {a b} {
								if {[string match "{{*}}" [set $v]]} {
									set inner	[string range [set $v] 2 end-2]
									#puts stderr "Extracting ($inner) from ([set $v])"
									if {[regexp {^(.*?)#(.*)$} $inner - base attr]} {
										set $v "\[json get \$p($base) [list $attr]\]"
									} else {
										set $v "\$p($inner)"
									}
								} elseif {[string match {{*{*}*}} [set $v]]} {
									set $v "\[_t [set $v]\]"
								}
							}
							set cexpr	"${a}eq${b}"

						}

						aws.partition {
							set cmd	[list [json get $arg fn]]
							json foreach a [json extract $arg argv] {
								append cmd " [list $service] [compile_arg $a 0]"
							}
						}

						aws.isVirtualHostableS3Bucket -
						aws.parseArn -
						getAttr -
						isValidHostLabel -
						parseURL -
						substring -
						uriEncode {
							set cmd	[list [json get $arg fn]]
							json foreach a [json extract $arg argv] {
								append cmd " [compile_arg $a 0]"
							}
						}

						default {
							error "Unhandled condition fn: \"[json get $arg fn]\""
						}
					}
					if {[info exists cexpr]} {
						if {[json exists $arg assign]} {
							set cexpr "!\[catch {expr [list $cexpr]} [list p([json get $arg assign])]\]"
						}
						#puts stderr "Compiling [json get $arg fn] [json extract $arg argv] -> ($cexpr)"
						if {$inexpr} {
							return $cexpr
						} else {
							return "\[expr {$cexpr}\]"
						}
					} else {
						#puts stderr "Compiling [json get $arg fn] [json extract $arg argv] -> ($cmd)"
						if {[json exists $arg assign]} {
							#return "!\[catch {$cmd} [list p([json get $arg assign])]\]"
							return "\[_a [list [json get $arg assign]] $cmd\]"
						} elseif {$inexpr} {
							return "\[try [list $cmd] on error {} {expr 0}\]"
						} else {
							return "\[$cmd\]"
						}
					}

				} else {
					error "Don't know how to compile arg \"$arg\""
				}
			}
			default {
				error "Unhandled arg type: [json type $arg]"
			}
		}
	} on ok compiled - on return compiled {
		if 1 {
			if {$inexpr} {
				#return -level 0 " track_term($compiled, $arg)"
				set compiled
			} else {
				#return "\[::tcl::mathfunc::track_term $compiled [list $arg]\]"
				set compiled
			}
		} else {
			set compiled
		}
	}
}

#>>>
proc compile_conditions conditions { #<<<
	upvar 1 leaves leaves  cexprmap cexprmap  service service
	set cexprs [json lmap condition $conditions {
		compile_arg $condition 1
	}]
	if {[llength $cexprs] == 0} {
		return 1
	} elseif {[llength $cexprs] == 1} {
		return aws_b([lindex $cexprs 0])
	} else {
		if 0 {
		join [lmap e $cexprs {
			if {![dict exists $cexprmap $e]} {
				dict set cexprmap $e %[dict size $cexprmap]%
			} 
			dict get $cexprmap $e
		}] &&
		} else {
			join $cexprs &&
		}
	}
}

#>>>
proc indent {depth str} { #<<<
	return "\n[string repeat \t $depth]$str\n[string repeat \t [expr {$depth-1}]]"
	#set str
}

#>>>
proc compile_rules {rules {depth 1}} { #<<<
	upvar 1 leaves leaves  errors errors  cexprmap cexprmap  service service
	set conditional_blocks	{}
	set test				if
	set seen_conditions		{}
	json foreach rule $rules {
		set comp_conditions	[compile_conditions [json extract $rule conditions]]
		if {[dict exists $seen_conditions $comp_conditions]} continue
		dict set seen_conditions $comp_conditions 1

		if {$test eq "elseif" && $comp_conditions eq "1"} {
			lappend conditional_blocks else
		} elseif {$test eq "if" && $comp_conditions eq "1"} {
		} else {
			lappend conditional_blocks $test $comp_conditions 
		}

		switch -exact -- [json get $rule type] {
			tree {
				set block [compile_rules [json extract $rule rules] [expr {$depth+([llength $conditional_blocks]?1:0)}]]
			}

			error {
				set err	[json get $rule error]
				set istemplate [string match *\u7b* $err]
				if {[dict exists $errors $err]} {
					set block "_e [list [dict get $errors $err] $istemplate] \$e"
				} else {
					set block "_e [list $err $istemplate]"
				}
			}

			endpoint {
				set template	[json normalize [json extract $rule endpoint]]
				#puts stderr "Emitting lindex [dict get $leaves $template] for $template"
				if {[dict exists $leaves $template]} {
					set block "_r [list [dict get $leaves $template]] \$l"
				} else {
					set block "_r [list $template]"
				}
			}

			default  {
				error "Unhandled rule type: \"[json get $rule type]\""
			}
		}

		if {0 && ![string match "puts \u7bblock*" $block]} {
			set blocknr	[incr ::_blocknr_seq]
			set block "puts {block $blocknr};$block"
			#append block " ;# $blocknr"
		}
		if {[llength $conditional_blocks] == 0} {
			lappend conditional_blocks $block
		} else {
			lappend conditional_blocks [indent $depth $block]
		}

		if {[llength $conditional_blocks] == 1} {
			# reduced if 1 {} - no further branches are possible
			break
		}
		if {$test eq "else"} {
			# Emitted else branch, no further branches are possible
			break
		}
		set test elseif
	}

	if {[llength $conditional_blocks] == 1} {
		lindex $conditional_blocks 0
	} else {
		set conditional_blocks
	}
}

#>>>
proc compile_endpoint_rules {definitions service_def} { #<<<
	set service_dir			[json get $service_def metadata service_dir]
	set latest				[json get $service_def metadata latest]
	set endpoint_rules_fn	[file join $definitions $service_dir $latest endpoint-rule-set-1.json]
	if {[file exists $endpoint_rules_fn]} {
		set endpoint_rules_json	[readfile $endpoint_rules_fn]
		set endpoint_params		[json extract $endpoint_rules_json parameters]
		aws::_undocument endpoint_params

		set cexprmap	{}
		lassign [extract_leaves $endpoint_rules_json] leaves errors
		#set errors	{}	;# DEBUG: disable deduplication of errors
		set service		[json get $service_def metadata service_name_orig]
		set comprules	[compile_rules [json extract $endpoint_rules_json rules]]
		set l_map	[if {[dict size $leaves]} {
			return -level 0 "set l {\n[join [lmap e [dict keys $leaves] {format "\t{%s}\n" $e}] {}]}"
		}]
		set e_map	[if {[llength $errors]} {
			return -level 0 "set e {\n[join [lmap {e idx} $errors {format "\t%s\n" [list $e]}] {}]}"
		}]
		if 0 {
			set trace_p		{trace add variable p write {apply {{n1 n2 op} {
				if {$n2 eq {}} {
					upvar 1 $n1 x
				} else {
					upvar 1 ${n1}($n2) x
				}
				set val	$x
				if {[string length $val] > 100} {set val [string range $val 0 96]...}
				puts stderr "${n1}($n2) set: ($val)"
			}}}
			}
		} else {set trace_p {}}

		if 0 {
			append trace_p {puts -------------------------------------------} \n
			append trace_p {if {[info exists p(Region)]} {set p(region) $p(Region)}} \n
			append trace_p {parray p} \n
		}

		#writefile /tmp/comprules-$service.tcl "array set p \$params\n$l_map\n$trace_p$e_map\n$comprules"
		set endpoint_rules	[list apply [list params "array set p \$params\n_debug {parray p}\n$l_map\n$trace_p$e_map\ntry {\n$comprules\nthrow {AWS ENDPOINT_RULES} {Could not resolve endpoint}\n} on return template {
		_debug {log notice \"endpoint_rules resolved template: (\$template)\"}
		if {\[json type \$template url\] eq \"object\"} {
			if {\[json exists \$template url ref\]} {
				json set template url \[json string \$p(\[json get \$template url ref\])\]
			} else {
				error \"Don't know how to compile endpoint url: \[json pretty \$template url\]\"
			}
		}
		set r	\[::aws::objecttemplate \$template \[array get p\]\]
		json set r _ service	\[list [json string $service]\]
		if {\[info exists p(Region)\]} {
			json set r _ region \[json string \$p(Region)\]
		}
		if {\[info exists p(_partition_result)\] && \[json exists \$p(_partition_result) services [list $service] \$p(Region) credentialScope\]} {
			json set r _ credentialScope	\[json extract \$p(_partition_result) services [list $service] \$p(Region) credentialScope\]
		} elseif {\[json exists \$r properties authSchemes 0 signingRegion\]} {
			json set r _ credentialScope region \[json extract \$r properties authSchemes 0 signingRegion\]
		} elseif {\[info exists p(Region)\]} {
			json set r _ credentialScope region \$p(Region)
		}
		_debug {log notice \"endpoint_rules substituted template: (\$r)\"}
		set r
	} trap terr {errmsg options} {\n\tthrow {AWS ENDPOINT_RULES} \[::aws::template \$errmsg \[array get p\]\]\n}" ::aws::_fn]]
	} else {
		set endpoint_params	{}
		set endpoint_rules [list apply [list {service params} {
			set einfo	[::aws::endpoint -service $service -region [dict get $params region]]
			::aws::objecttemplate $einfo [dict merge $params [json get $einfo]]
		} ::aws::_fn] [json get $service_def metadata service_name_orig]]
	}

	list $endpoint_rules $endpoint_params
}

#>>>
# Endpoint rules compilation >>>

proc build_aws_services args { #<<<
	parse_args $args {
		-ver			{-required}
		-definitions	{-required -# {Directory containing the service definitions from botocore}}
		-prefix			{-default tm -# {Where to write the service tms}}
		-services		{-default {} -# {Supply a list of services to only build those, default is to build all}}

		-ziplet			{-name output_mode -multi -default ziplet}
		-brlet			{-name output_mode -multi}
		-plain			{-name output_mode -multi}
	}

	file mkdir [file join $prefix aws]

	set endpoints	[json normalize [readfile $definitions/endpoints.json]]
	json set endpoints partitions [json amap partition [json extract $endpoints partitions] {
		json set partition regionRegex	[json string [string map {\\w [a-zA-Z0-9_] \\d [0-9] \\- -} [json get $partition regionRegex]]]
	}]

	set partitions	{{}}
	json foreach partition [json extract [readfile $definitions/partitions.json] partitions] {
		json set partitions [json get $partition id] $partition
	}

	chantricks::with_file h [file join $prefix aws endpoints-$ver.tm] wb {
		switch -exact -- $output_mode {
			ziplet {                         set decompress {zlib gunzip}                                }
			brlet  { package require brotli; set decompress {package require brotli; brotli::decompress} }
			plain  {                         set decompress {return -level 0}                            }
			default {error "Mode not supported: \"$output_mode\""}
		}
		puts $h [string map [list \
			%decompress%	$decompress \
		] {
			namespace eval ::aws {}
			apply {{} {
				variable endpoints
				variable partitions
				set h		[open [info script] rb]
				set bytes	[try {read $h} finally {close $h}]
				set eof		[string first \x1A $bytes]
				lassign [encoding convertfrom utf-8 [%decompress% [string range $bytes $eof+1 end]]] \
					endpoints partitions
			} ::aws}
		}]
		set utf8tail	[encoding convertto utf-8 [list $endpoints $partitions]]
		switch -exact -- $output_mode {
			ziplet { puts -nonewline $h \x1A[zlib gzip $utf8tail -level 9] }
			brlet  { puts -nonewline $h \x1A[brotli::compress -quality 11 $utf8tail] }
			plain  { puts -nonewline $h \x1A$utf8tail }
		}
	}

	set partition	[json extract $endpoints partitions 0]
	set defaults	[json get $partition defaults]

	set by_protocol	{
		json		{}
		rest-json	{}
		query		{}
		rest-xml	{}
	}
	foreach service_dir [glob -type d -tails -directory $definitions *] {
		set latest	[lindex [lsort -dictionary -decreasing [glob -type d -tails -directory [file join $definitions $service_dir] *]] 0]
		if {$latest eq ""} {
			error "Couldn't resolve latest version of $service_dir"
		}
		set service_fn	[file join $definitions $service_dir $latest service-2.json]
		if {![file exists $service_fn]} {
			error "Couldn't read definition of $service_dir/$latest from $service_fn"
		}
		set service_def			[readfile $service_fn]
		set service_name_orig	[lindex [file split $service_dir] 0]
		set service_name		[string map {- _} $service_name_orig]

		if {[llength $services] > 0 && $service_name ni $services} continue

		#puts "dir $service_dir endpointprefix: [json get $service_def metadata endpointPrefix], exists: [json exists $partition services [json get $service_def metadata endpointPrefix]], protocol: [json get $service_def metadata protocol]"
		set metadata	[json extract $service_def metadata]
		json set service_def metadata service_name		[json string $service_name]
		json set service_def metadata service_name_orig	[json string $service_name_orig]
		json set service_def metadata service_dir		[json string $service_dir]
		json set service_def metadata latest			[json string $latest]
		set protocol	[json get $service_def metadata protocol]
		if {$service_name eq "sqs"} {
			# SQS declares itself to use the "query" protocol, but that is a legacy mode, and prefers json
			# The botocore definitions describe the json shapes, and do not correspond with the query xml responses *shrug*
			set protocol	json
			json set service_def metadata protocol $protocol
			json set service_def metadata targetPrefix AmazonSQS
			json set service_def metadata jsonVersion 1.0
		}
		dict lappend by_protocol $protocol $service_def
	}

	dict for {protocol services} $by_protocol {
		set service_sort {{a b} {
			string compare [json get $a metadata service_name] [json get $b metadata service_name]
		}}
		puts "$protocol:\n\t[join [lmap service [lsort -command [list apply $service_sort] $services] {
			format {%30s: %s} [json get $service metadata service_name] [json get $service metadata serviceFullName]
		}] \n\t]"
	}

	set total_raw			0
	foreach service_def [list {*}[dict get $by_protocol json] {*}[dict get $by_protocol rest-json] {*}[dict get $by_protocol query]] { #<<<
		set def			$service_def

		#puts "creating ::aws::[json get $service_def metadata service_name]"
		set protocol	[json get $service_def metadata protocol]
		set service_code	{namespace export *;namespace ensemble create -prefixes no;namespace path {::parse_args ::rl_json ::aws ::aws::helpers};variable endpoint_cache {};}

		lassign [compile_endpoint_rules $definitions $service_def] endpoint_rules endpoint_params
		#append service_code	[list variable endpoint_params $endpoint_params] \n
		append service_code "proc endpoint_rules params {$endpoint_rules \$params}" \n
		append service_code [list variable protocol $protocol] \n
		append service_code	{variable ei ::aws::_eir} \n

		set responses	{}
		set exceptions	{}
		json foreach {op opdef} [json extract $def operations] {
			try {
				set static		{}
				set params		{}
				set cxparams	{}
				set copy_to_cx	{}
				set cx_suppress	{
					UseObjectLambdaEndpoint	1
				}
				set builtins	{}

				if {[json exists $opdef staticContextParams]} {
					json foreach {k v} [json extract $opdef staticContextParams] {
						dict set cxparams		$k [json get $v value]
						dict set cx_suppress	$k 1
					}
				}

				set cmd		[aws from_camel $op]
				#puts stderr "[json get $def metadata service_name]: op: ($op) -> cmd: ($cmd), opdef: [json pretty $opdef]"

				unset -nocomplain w
				switch -exact -- [json get -default 1.1 $def metadata jsonVersion] {
					1.0 {
						# Copilot hint: perhaps it knows something I don't:
						#if {[json exists $opdef input]} {
						#	set w	[json get $opdef input wrapper]
						#}
						set c	{application/x-amz-json-1.0}
					}
					1.1 {
						# Copilot hint: perhaps it knows something I don't:
						#if {[json exists $opdef input]} {
						#	set w	[json get $opdef input payload]
						#}
						set c	{application/x-amz-json-1.1}
					}
					default {
						error "Unknown jsonVersion: [json get $def metadata jsonVersion]"
					}
				}
				set u			{}
				set hm			{}
				set q			{}
				if {$protocol eq "query"} {
					lappend q		Action _a
					lappend static	[list set _a $op]
				}

				set b			{}
				if {[json exists $opdef input]} {
					set t	[aws::build::compile_input \
						-protocol			$protocol \
						-params				params \
						-cxparams			cxparams \
						-copy_to_cx			copy_to_cx \
						-cx_suppress		cx_suppress \
						-uri_map			u \
						-query_map			q \
						-header_map			hm \
						-payload			b \
						-shapes				[json extract $def shapes] \
						-shape				[json get $opdef input shape] \
						-endpoint_params	$endpoint_params \
						-builtins			builtins \
					]
				} else {
					set t	{}
				}

				if {[llength $builtins]} {
					lappend static	[list ::aws::_builtins {*}$builtins]
				}

				#lappend static	[list set cxparams $cxparams]
				if {[llength $copy_to_cx] > 0} {
					lappend static	[list _copy2cx {*}$copy_to_cx]
				}
				#lappend static {puts stderr "cxparams: ($cxparams)"}
				#lappend static	[list dict set params service [list $service_name_orig]]
				#lappend static	[list set op $op]
				#lappend static {puts stderr "compute endpoint, first: [timerate {endpoint_rules $cxparams} 1 1]"}
				#lappend static {puts stderr "compute endpoint: [timerate {endpoint_rules $cxparams}]"}
				#lappend static {_debug {log notice "cx_params: ($cxparams)"}}
				#lappend static {set endpoint	[endpoint_rules $cxparams]}
				#lappend static {_debug {log notice "computed endpoint: endpoint_rules($cxparams) -> ($endpoint)"}}

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
		unset -nocomplain compressed_size
		#variable ::aws::[json get $service_def metadata service_name]::def $service_def
		switch -exact -- $output_mode {
			ziplet {
				set zipped				[zlib gzip [encoding convertto utf-8 $service_code] -level 9]
				set ziplet				[encoding convertto utf-8 {package require aws 2;::aws::_load}]\x1A$zipped
				set compressed_size		[string length $ziplet]
				incr total_compressed	$compressed_size
			}
			brlet {
				package require brotli
				set brlet				[encoding convertto utf-8 {package require aws 2;::aws::_load_br}]\u1A[brotli::compress -quality 11 [encoding convertto utf-8 $service_code]]
				set compressed_size		[string length $brlet]
				incr total_compressed	$compressed_size
				#puts stderr "[json get $service_def metadata service_name] ([string length $service_code] chars, [string length $zipped] gzipped bytes), brlet: [string length $brlet]"
			}
			plain {
			}
		}
		puts stderr "[json get $service_def metadata service_name] ([string length $service_code] chars[if {[info exists compressed_size]} {subst {, $compressed_size compressed bytes}}])"
		incr total_raw	[string length $service_code]
		if {[json get $service_def metadata service_name] in {}} {
			puts stderr [highlight -regexp {^proc (create_bucket|list_buckets|delete_bucket)%.*$} $service_code]
		}
		set aws_ver	[package require aws 2]
		switch -exact -- $output_mode {
			ziplet  { writebin  [file join $prefix aws/[string map {- _} [json get $service_def metadata service_name]]-$aws_ver.tm] $ziplet       }
			brlet   { writebin  [file join $prefix aws/[string map {- _} [json get $service_def metadata service_name]]-$aws_ver.tm] $brlet        }
			plain   { writefile [file join $prefix aws/[string map {- _} [json get $service_def metadata service_name]]-$aws_ver.tm] [aws::_reconstruct {} $service_code] }
			default { error "Unknown output mode \"$output_mode\"" }
		}
	}
	#>>>

	# rest-xml protocol services <<<
	foreach service_def [dict get $by_protocol rest-xml] {
		#if {[json get $service_def metadata service_name] ni {route53}} continue
		aws::_undocument service_def

		lassign [compile_endpoint_rules $definitions $service_def] endpoint_rules endpoint_params

		#puts stderr "endpoint_params: [json pretty $endpoint_params]"
		#if {[json get $service_def metadata service_name] eq "s3"} {
		#	puts stderr "endpoint_rules: $endpoint_rules"
		#}
		#puts "endpoint_rules: [string length $endpoint_rules] chars, zipped: [string length [zlib gzip [encoding convertto utf-8 $endpoint_rules] -level 9]] bytes"
		set service_code	[string trim [string map [list \
			%service_name%		[list [json get $service_def metadata service_name]] \
			%service_name_orig%	[list [json get $service_def metadata service_name_orig]] \
			%protocol%			[list [json get $service_def metadata protocol]] \
			%endpoint_params%	[list [json normalize $endpoint_params]] \
			%service_def%		[list $service_def] \
			%endpoint_rules%	$endpoint_rules \
		] {
namespace eval ::aws::%service_name% {
	namespace path {::parse_args ::rl_json ::aws ::aws::helpers}
	namespace export *
	namespace ensemble create -prefixes no -unknown ::aws::_compile_rest-xml_op
	variable service_def		%service_def%
	variable protocol			%protocol%
	variable service_name_orig	%service_name_orig%
	variable endpoint_params	%endpoint_params%
	variable responses			{}

	#proc ::tcl::mathfunc::track_term {term msg} {
	#	set frame	[info frame -1]
	#	#puts stderr [string range $frame 0 200]...
	#	::aws::helpers::_debug {puts stderr "term ($msg): -> ([string range $term 0 200]), [dict get $frame file]:[dict get $frame line]"}
	#	set term
	#}
	proc endpoint_rules params {%endpoint_rules% $params}
}
		}]]

		incr total_raw	[string length $service_code]
		set aws_ver	[package require aws 2]
		switch -exact -- $output_mode {
			ziplet {
				set zipped				[zlib gzip [encoding convertto utf-8 $service_code] -level 9]
				set ziplet				[encoding convertto utf-8 {package require aws 2;::aws::_load_ziplet}]\x1A$zipped
				set compressed_size		[string length $ziplet]
				incr total_compressed	$compressed_size
				writebin  [file join $prefix aws/[string map {- _} [json get $service_def metadata service_name]]-$aws_ver.tm] $ziplet
			}
			brlet {
				package require brotli
				set brlet				[encoding convertto utf-8 {package require aws 2;::aws::_load_brlet}]\u1A[brotli::compress -quality 11 [encoding convertto utf-8 $service_code]]
				set compressed_size		[string length $brlet]
				incr total_compressed	$compressed_size
				#puts stderr "[json get $service_def metadata service_name] ([string length $service_code] chars, [string length $zipped] gzipped bytes), brlet: [string length $brlet]"
				writebin  [file join $prefix aws/[string map {- _} [json get $service_def metadata service_name]]-$aws_ver.tm] $brlet
			}
			plain {
				writefile [file join $prefix aws/[string map {- _} [json get $service_def metadata service_name]]-$aws_ver.tm] [aws::_reconstruct {} $service_code]
			}
			default { error "Unknown output mode \"$output_mode\"" }
		}
	}
	# rest-xml protocol services >>>

	puts "total_raw: $total_raw"
	if {[info exists total_compressed]} {
		puts "total_compressed: $total_compressed"
	}
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
