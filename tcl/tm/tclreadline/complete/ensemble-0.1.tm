namespace eval ::tclreadline::complete {
	namespace path {
		::tclreadline
	}

	proc ensemble {cmd text start end line pos mod} { #<<<
		try {
			set prefline	[string range $line 0 $start]
			set ptr	1
			# Walk the chain of ensembles
			while {[namespace ensemble exists $cmd]} {
				if {[incr breaker] > 5} {error Breaker}
				set cfg	[namespace ensemble configure $cmd]
				set ns			[dict get $cfg -namespace]
				set subcommands	[dict get $cfg -subcommands]
				set map			[dict get $cfg -map]
				if {[llength $subcommands] > 0} {
					# If defined, subcommands limit the valid subcommands to a subset of map
					set map	[dict filter $map script {k v} {expr {
						$k in $subcommands
					}}]
				}
				foreach subcmd $subcommands {
					if {![dict exists $map $subcmd]} {
						dict set map $subcmd $subcmd
					}
				}
				if {[dict size $map] > 0} {
					set subcommands	[dict keys $map]
				}
				set exportpats	[namespace eval $ns {namespace export}]
				if {[llength $subcommands] == 0} {
					# If both -subcommands and -map are empty, populate map with the exported commands
					set nscmds		[lmap e [info commands ${ns}::*] {
						set e	[namespace tail $e]
						set matched	0
						foreach pat $exportpats {
							if {[string match $pat $e]} {
								set matched	1
								break
							}
						}
						if {!$matched} continue
						set e
					}]
					foreach subcmd $nscmds {
						dict set map $subcmd ${ns}::$subcmd
					}
				}
				#puts stderr "ensemble completer got:\n\t[join [lmap v {cmd text start end line pos mod cfg} {format {%5s: (%s)} $v [set $v]}] \n\t]"
				#puts stderr "map:\n\t[join [lmap {k v} $map {format "%20s -> %-30s %d" [list $k] [list $v] [namespace ensemble exists $v]}] \n\t]"
				#for {set i 0} {$i < [Llength $prefline]} {incr i} {
				#	puts stderr "word $i: ([Lindex $prefline $i])"
				#}

				#puts stderr "ptr: ($ptr), pos: ($pos)"
				if {$ptr < $pos} {
					set thisword	[Lindex $prefline $ptr]
					incr ptr
					if {[dict exists $map $thisword]} {
						#puts "chaining ($cmd) -> ([dict get $map $thisword])"
						set cmd	[dict get $map $thisword]
						continue
					} else {
						#puts stderr "thisword ($thisword) invalid (not in map [dict keys $map])"
						return ""
					}
				} elseif {$ptr == $pos} {
					# This is the completion target
					#set thiswordpref	[Lindex $prefline $ptr]
					#puts stderr "Completing ($text) from possibilities: [dict keys $map]"
					return [CompleteFromList $text [dict keys $map]]
				} else {
					error "ptr ran off the end"
				}
			}
			#puts stderr "cmd ($cmd) not an ensemble, ptr: ($ptr), pos: ($pos)"
			# If it's a proc, look for parse_args
			try {
				set arglist	[info args $cmd]
				set body	[info body $cmd]
				#puts stderr "arglist: ($arglist), body: ($body)"
				if {![string match *parse_args* $body]} return
				#puts stderr "Uses parse_args, digging deeper"

				# Match off remaining command words with proc arguments
				set args_remaining	$arglist
				set parseargs_input	{}
				while {$ptr <= $pos && [llength $args_remaining]} {
					set args_remaining	[lassign $args_remaining argname]
					if {[lindex $argname 0] eq "args"} {
						while {$ptr < $pos} {
							lappend parseargs_input	[Lindex $prefline $ptr]
							incr ptr
						}
						#puts stderr "Assigned parseargs_input: ($parseargs_input)"
						break
					}
					#puts stderr "Assigned arg [list [lindex $argname] 0] := [list [Lindex $prefline $ptr]]"
					incr ptr
				}
				if {[lindex $argname 0] ne "args"} {
					#puts stderr "Not in args"
					if {[llength $argname] == 1} {
						return [DisplayHints <$argname>]
					} else {
						return [DisplayHints ?$argname?]
					}
				}
				#puts stderr "Would complete ($text) for parse_args spec, with ($parseargs_input) input"
				# TODO: parse $body with parsetcl and find parse_args argspec, then feed the $parseargs_input into an assigner that consumes it to match the parse_args argspec, and then present choices for the context word that is being completed (either an option, or a value for an option)
			} on error {errmsg options} {
				#puts stderr "Couldn't parse $cmd as a proc: [dict get $options -errorinfo]"
				return ""
			}
		} on error {errmsg options} {
			puts stderr "Unhandled error in completer: [dict get $options -errorinfo]"
		}
		return ""
	}

	#>>>
}
# vim: ft=tcl ts=4 shiftwidth=4 foldmethod=marker foldmarker=<<<,>>>
