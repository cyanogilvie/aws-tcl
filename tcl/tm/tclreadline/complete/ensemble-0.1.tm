try {
namespace eval ::tclreadline::complete {
	namespace eval helpers {
		package require parsetcl
		package require parse_args

		namespace path {
			::parse_args
			::parsetcl
		}

		namespace eval cx {
			namespace export *
			namespace ensemble create -prefixes 0

			namespace path [list {*}{
				::parse_args
				::parsetcl
			} [uplevel 1 {namespace current}]]

			variable varchange_hooks	{}
			proc on {event args} { #<<<
				variable varchange_hooks

				switch -exact $event {
					varchange {
						parse_args $args {
							varname		{-required}
							cb			{-required}
							script		{-required}
						}

						set hold	$varchange_hooks
						lappend varchange_hooks [list $varname "upvar 1 cx cx; $cb" [uplevel 1 {namespace current}]]
						try {
							uplevel 1 $script
						} on break {} - on continue {} {
							dict incr o -level 1
							return -options $o $r
						} on return {r o} {
							dict set o -code return
							dict incr o -level 1
							return -options $o $r
						} finally {
							set varchange_hooks	$hold
						}
					}

					default {
						error "Unknown event: \"$event\""
					}
				}
			}

			#>>>
			proc new_cx args { #<<<
				parse_args $args {
					-cx			{-default cx -name cxvar}
					-namespace	{}
				}
				upvar 1 $cxvar cx

				set cx {
					vars		{}
					exists		{}
					namespace	{}
					aliases		{}
				}

				set cx
			}

			#>>>
			proc set_var args { #<<<
				variable varchange_hooks

				parse_args $args {
					-varname		{-required -# {word node}}
					-value			{-# {word node(s)}}
					-const			{-# {literal value(s)}}
					-provenance		{-args 2 -# {first arg: string description, second arg: word node that is the source of the value}}

					-replace		{-multi -name mode -default replace}
					-append			{-multi -name mode}
					-lappend		{-multi -name mode -# {-value / -const is a list}}

					-cx				{-default cx -name cxvar}
				}
				upvar 1 $cxvar cx

				if {![domNode $varname hasAttribute value]} {
					# Can't resolve the varname, have to clear out what we know about
					# vars and constants, other than those known to exist
					dict set cx vars		{}
					dict set cx exists		[dict filter $cx value 1]	;# Can't know if this set a previously unset variable, but we can keep knowledge about any definitely set variables
					if {[info exists value]} {
						dict set cx unresolved_vars $varname nodes $value
					}
					return
				}

				set var	[domNode $varname getAttribute value]

				unset -nocomplain newnodes newconst

				switch -exact -- $mode {
					replace { #<<<
						if {[info exists value]} {
							set newnodes		[list $value]
						}

						if {[info exists const]} {
							set newconst		$const
						} elseif {[info exists value] && [domNode $value hasAttribute value]} {
							set newconst		[domNode $value getAttribute value]
						}
						#>>>
					}
					append { #<<<
						if {[info exists value]} {
							if {[dict exists $cx vars $var nodes]} {
								# TODO: combine with the existing word, error if multiple
								set old	[dict get $cx vars $var nodes]
								if {[llength $old] > 1} {
									# Technically not an error, but we can't represent it (easily)
									error "Appending to a list"
								}

								set old	[lindex $old 0]
								foreach part [xpath $value *] {
									$old appendChild [domNode $part cloneNode -deep]
								}
								set newnodes [list $old]
							} elseif {[dict exists $cx exists $var] && [dict get $cx exists $var] == 0} {
								# Known to not exist
								set newnodes [list $value]
							} else {
								# Can't resolve the prior state of the variable
							}
						}

						unset -nocomplain oldvalue
						if {[const $varname oldvalue] || ([dict exists $cx exists $var] && [dict get $cx exists $var] == 0)} {
							# We have a constant value for it before, or it definitely didn't exist
							if {
								![info exists const] &&
								[info exists value] &&
								[domNode $value hasAttribute value]
							} {
								set const	[domNode $value getAttribute value]
							}
							if {[info exists const]} {
								append oldvalue	$const
								set newconst	$oldvalue
							}
						}
						#>>>
					}
					lappend { #<<<
						if {[info exists value]} {
							if {[dict exists $cx vars $var nodes]} {
								# TODO: combine with the existing word, error if multiple
								set old	[dict get $cx vars $var nodes]
								lappend old $value
								set newnodes [list $old]
							} elseif {[dict exists $cx exists $var] && [dict get $cx exists $var] == 0} {
								# Known to not exist
								set newnodes $value
							} else {
								# Can't resolve the prior state of the variable
							}
						}

						unset -nocomplain oldvalue
						if {[const $varname oldvalue] || ([dict exists $cx exists $var] && [dict get $cx exists $var] == 0)} {
							# We have a constant value for it before, or it definitely didn't exist
							if {
								![info exists const] &&
								[info exists value] &&
								[all_const $value]
							} {
								set const	[lmap e $value {domNode $e getAttribute value}]
							}
							if {[info exists const]} {
								lappend oldvalue	{*}$const
								set newconst	$oldvalue
							}
						}
						#>>>
					}
					default {
						error "Unhandled mode \"$mode\""
					}
				}

				if {[info exists newnodes]} {
					dict set cx vars $var nodes $newnodes
				} elseif {[dict exists $cx vars $var]} {
					dict unset cx vars $var nodes
				}

				if {[info exists newconst]} {
					dict set cx vars $var const $newconst
				} elseif {[dict exists $cx vars $var]} {
					dict unset cx vars $var const
				}

				dict set cx exists $var 1

				if {![info exists provenance]} {
					if {[info exists value]} {
						set source	[xpath [lindex $value 0] { ancestor-or-self::word[@idx][1] }]
						if {[llength $source]} {
							set provenance [list "from" [lindex $source 0]]
						}
					}
				}

				if {[info exists provenance]} {
					if {[dict exists $cx vars $varname provenance]} {
						set old	[dict get $cx vars $varname provenance]
					}
					lappend old $provenance
					dict set cx vars $varname $old
				}

				foreach hook $varchange_hooks {
					apply $hook $var
				}
			}

			#>>>
			proc unset_var args { #<<<
				variable varchange_hooks

				parse_args $args {
					-varname	{-required -# {word node}}
					-cx			{-default cx -name cxvar}
				}
				upvar 1 $cxvar cx

				if {![domNode $varname hasAttribute value]} {
					# Can't resolve the varname, have to clear out what we know about
					# vars and constants, other than those known not to exist
					dict set cx vars		{}
					dict set cx exists		[dict filter $cx value 0]	;# Can't know if this set a previously unset variable, but we can keep knowledge about any definitely unset variables
					dict set cx unresolved_vars $varname unset

					foreach hook $varchange_hooks {
						apply $hook $var
					}
					return
				}

				set var	[domNode $varname getAttribute value]
				try {
					dict unset cx vars $var
				} on error {errmsg options} {
					puts stderr "Error trying to unset ($var) from cx: ($cx)"
					return -options $options $errmsg
				}
				dict set cx exists $var 0

				foreach hook $varchange_hooks {
					apply $hook $var
				}
			}

			#>>>
			proc const args { #<<<
				parse_args $args {
					-cx			{-default cx -name cxvar}
					varname		{-required}
					value		{-alias -required}
				}
				upvar 1 $cxvar cx

				if {![domNode $varname hasAttribute value]} {
					return 0
				}

				set var	[domNode $varname getAttribute value]
				if {[dict exists $cx vars $var const]} {
					set value	[dict get $cx vars $var const]
					return 1
				}
				return 0
			}

			#>>>
		}

		proc idx2line {idx linestarts lineofs} { #<<<
			set line	[lsearch -sorted -increasing -bisect -integer $linestarts $idx]
			#if {$line == -1} {error "Invalid idx \"$idx\", before the start of the first line"}
			if {$line == -1} {return [list 0 [+ $idx 1]]}
			set linestart	[lindex $linestarts $line]
			list [+ $line $lineofs 1] [::tcl::mathfunc::max 0 [- $idx $linestart -1]]
		}

		#>>>
		proc reindent {txt indentstr} { #<<<
			regsub -all {\n\s*} $txt \n$indentstr
		}

		#>>>
		proc reconstitute {node args} { #<<<
			global dbg_indent
			parse_args $args {
				-inexpr					{-boolean}
				-parent_op_precedence	{-default 100}
				-op_num					{-default 1}
				-indent					{}
			}

			try {
				if {[domNode $node hasAttribute deleted]} return
			} on error {} {
				return
			}

			#puts stderr "reconstitute, inexpr: $inexpr, parent_op_precedence: $parent_op_precedence, op_num: $op_num, node: [domNode $node asXML]"

			# inexpr - the parse info returned by Tcl_ParseExpr has been substantially
			# transformed (into a stack) and doesn't match the input text.  Special
			# considerations need to be taken when reconstituting it.
			set res	{}

			if {[domNode $node hasAttribute indent]} {
				set indent_level	[domNode $node getAttribute indent]
				set indent			($indent_level)[string repeat \t $indent_level]
			} else {
				if {![info exists indent]} {
					set indent			""
				}
			}

			if 0 {

							if {[domNode $node hasAttribute indent]} {
								set indent	[domNode $node getAttribute indent]
								set indentstr	\n[string repeat \t $indent]

								switch -exact -- $as_type {
									"expr" {
										# TODO: inspect @orig to see if it starts with whitespace containing a newline
										regexp {^(?:\s*(?:\n|#.*\n))?} [domNode $as_node getAttribute orig] leading_whitespace
										set has_newline	[string match *\n $leading_whitespace]
										if {$has_newline} {
											append res	$leading_whitespace
										}
									}

									"script" - "list" {
										set leading_whitespace_node	[xpath $as_node {*[not(@deletd)][1 and self::space]}]
										set leading_whitespace	[domNode $leading_whitespace_node text]
										set has_newline	[regexp {^\s*(?:\n|#.*\n)} $leading_whitespace]
										puts "leading_whitespace, has_newline ($has_newline): [regexp -all -inline .. [binary encode hex $leading_whitespace]] ($leading_whitespace)"
										if {$has_newline} {
											set leading_whitespace	[apply $reindent $leading_whitespace]
										}
										append res	$leading_whitespace
									}
								}
								if {$has_newline} {
									set children	[xpath $node { *[not(@noise or @deleted)] }]
									if {[incr ::inspect_seq] == 2} {
										puts stderr "Reconstitute $as_type with indent $indent:\n[string range [domNode $as_node asXML] 0 1024]..."
										error stop
									}
								} else {
									set res	[reconstitute $as_node]
								}
							} else {
								set res	[reconstitute $as_node]
							}
			}

			switch -exact -- [domNode $node nodeName] {
				expr {
					#puts stderr "expr: [domNode $node asXML]"
					#set orig	[xpath $node {string(subexpr[1]/@orig)}]
					set and_or_operators	[xpath $node {count(descendant::operator[@name='&&' or @name='||'])}]
					#puts stderr "expr {$orig}, and_or_operators: $and_or_operators -------------------------------------------------------"
					if {$and_or_operators > 1} {
						set indent	[parsetcl indent [xpath $node {ancestor::command[1]}]]
						append indent	\t
						append res	"\n$indent"
					}
					foreach child [domNode $node childNodes] {
						append res [reconstitute $child -inexpr -indent $indent]
					}
					if {$and_or_operators > 1} {
						set indent	[string range $indent 0 end-1]
						append res	"\n$indent"
					}
					#puts stderr "--->$res<---"
				}

				script {
					#if {$inexpr} { append res "\[" }

					if {[xpath $node {
						boolean(
							/tcl/script[@indent] and
							command[
								@name="if" and
								word[2]/as/expr/subexpr//var[@name="arglen"]
							]
						)
					}]} {
						#error "Bang:\n[domNode $node asXML]"
					}

					# If the script contains no commands, reduce it to {}
					if {[xpath $node {
						boolean(command)
					}]} {
						set children	[domNode $node childNodes]
						if {[info exists indent_level]} {
							set leading_whitespace	{}
							while {[llength $children] > 0} {
								set child	[lindex $children 0]
								if {[domNode $child nodeName] ni {space comment}} break
								set children	[lrange $children[unset children] 1 end]
								append leading_whitespace	[domNode $child text]
							}
							set has_newline	[regexp {^\s*(?:\n|#.*\n)} $leading_whitespace]
							#puts "leading_whitespace, has_newline ($has_newline): [regexp -all -inline .. [binary encode hex $leading_whitespace]] ($leading_whitespace)"
							if {$has_newline} {
								set leading_whitespace	[reindent $leading_whitespace $indent]
							}
							append res	$leading_whitespace

							unset -nocomplain pending_whitespace
							while {[llength $children] > 0} {
								set children	[lassign $children[unset children] child]

								switch -exact -- [domNode $child nodeName] {
									space - comment {
										append pending_whitespace [reconstitute $child]
									}
									default {
										if {[info exists pending_whitespace]} {
											append res	[reindent $pending_whitespace $indent]
											unset pending_whitespace
										}
										append res [reconstitute $child]
										set end	[xpath $child string(end)]
										if {$end eq "\n"} {
											append pending_whitespace	$end
										}
									}
								}
							}

							if {[info exists pending_whitespace]} {
								append res	[reindent $pending_whitespace ([expr {$indent_level-1}])[string repeat \t [expr {$indent_level-1}]]]
							}
						} else {
							foreach child $children {
								append res	[reconstitute $child]
							}
						}
					}


					#if {$inexpr} { append res "\]" }
				}

				operator {
					set op	[domNode $node getAttribute name]

					set precedence	{
						**	2

						*	3
						/	3
						%	3

						+	4
						-	4

						<<	5
						>>	5

						<	6
						>	6
						<=	6
						>=	6

						==	7
						!=	7

						eq	8
						ne	8

						in	9
						ni	9

						&	10

						^	11

						|	12

						&&	13

						||	14

						?	15
					}

					set mathfunc	0
					set subexprs	[xpath $node { subexpr[not(@deleted)] }]
					if {[llength $subexprs] == 1} {
						# All unitary operators have the highest precedence (1)
						if {$op in {+ - ~ !}} {
							set op_precedence	1
						} else {
							# We're a math func
							set mathfunc		1
							set op_precedence	100
						}
					} else {
						if {[dict exists $precedence $op]} {
							set op_precedence	[dict get $precedence $op]
						} else {
							set mathfunc		1
							set op_precedence	100
						}
					}

					set needs_paren	[expr {
						$op_precedence > $parent_op_precedence ||
						$op_precedence == $parent_op_precedence && (
							($op eq "**" && $op_num == 1) ||
							($op ne "**" && $op_num > 1)
						)
					}]

					if {$needs_paren && !$mathfunc} {
						append res	(
						if {$indent ne ""} {
							append indent \t
							append res \n$indent
						}
					}

					#puts stderr "${dbg_indent}operator node: $op, precedence: $op_precedence, mathfunc: $mathfunc"

					set sub_op_num	0
					set operands	[lmap e $subexprs {
						incr sub_op_num
						#puts stderr "${dbg_indent}reconstituted subexpr operand:\n[domNode $e asXML] => ->[reconstitute $e -inexpr -parent_op_precedence $parent_op_precedence -op_num $sub_op_num]<- op_precedence $op_precedence, parent_op_precedence: $parent_op_precedence, passed parent_op_precedence: $parent_op_precedence"
						set t	[reconstitute $e \
							-inexpr \
							-parent_op_precedence	$op_precedence \
							-op_num					$sub_op_num \
							-indent					$indent]
						#puts stderr "${dbg_indent}op $sub_op_num: ->$t<-"
						set t
					}]

					if {$mathfunc} {
						append res	${op}([join $operands {, }])

					} else {
						#if {1 || $op_precedence == $parent_op_precedence} {
						#	puts stderr "${dbg_indent}op: $op, op_num: $op_num, needs_paren: $needs_paren"
						#}
						#puts stderr "${dbg_indent}operator: $op, operands: $operands, op_precedence $op_precedence, parent_op_precedence: $parent_op_precedence"

						switch -exact -- [llength $operands] {
							1 { # Unary operators
								append res "$op[lindex $operands 0]"
							}

							2 { # Binary operators
								switch -exact -- $op {
									**      { append res "[lindex $operands 0]$op[lindex $operands 1]" }
									&& - || {
										if {$indent eq ""} {
											append res "[lindex $operands 0] $op [lindex $operands 1]"
										} else {
											append res "[lindex $operands 0] $op\n$indent[lindex $operands 1]"
										}
									}
									default { append res "[lindex $operands 0] $op [lindex $operands 1]" }
								}
							}

							3 { # Ternary operators
								append res "[lindex $operands 0] $op [lindex $operands 1] : [lindex $operands 2]"
							}

							default {
								error "Invalid number of operands to $op: [llength $operands]: [list $operands]"
							}
						}
					}

					if {$needs_paren && !$mathfunc} {
						if {$indent ne ""} {
							set indent	[string range $indent 0 end-1]
							append res	\n$indent
						}
						append res	)
					}

					set indent	[string range $indent 0 end-1]
				}

				subexpr {
					append dbg_indent	\t
					set quoted	[domNode $node getAttribute quoted none]
					switch -exact -- $quoted {
						quote {append res "\""}
						brace {append res "\{"}
					}
					#puts stderr "subexpr ([xpath $node {string(@orig)}]) quoted: $quoted [domNode $node asXML]"
					foreach child [xpath $node {*[not(@deleted)]}] {
						if {[domNode $child nodeName] eq "script"} { append res	"\[" }
						if {$quoted eq "none"} {
							append res [reconstitute $child -inexpr -parent_op_precedence $parent_op_precedence -op_num $op_num -indent $indent]
						} else {
							append res [reconstitute $child -parent_op_precedence $parent_op_precedence -op_num $op_num -indent $indent]
						}
						if {[domNode $child nodeName] eq "script"} { append res	"\]" }
					}
					switch -exact -- $quoted {
						quote {append res "\""}
						brace {append res "\}"}
					}
					set dbg_indent	[string range $dbg_indent 0 end-1]
				}

				command {
					if {[domNode $node hasAttribute indent]} {
						append res	[domNode $node getAttribute indent]
					}
	
					set saw_end	0
					foreach child [xpath $node *] {
						switch -exact -- [domNode $child nodeName] {
							end {
								set saw_end	1
							}
							default {
							}
						}
						append res [reconstitute $child]
					}
					if {!$saw_end} {
						if {[xpath $node {count(following-sibling::command)=0}]} {
							# last command in the script
						} else {
							append res	\n
						}
					}
				}

				tcl - list - subst {
					foreach child [xpath $node *] {
						append res [reconstitute $child]
					}
				}

				var {
					#set varname	[domNode $node getAttribute name]
					set varname	[xpath $node {
						string(text[1])
					}]
					if {[string match "*\}" $varname]} {
						# TODO: Convert this to [set $varname] / [set $varname($index)]
						error "Cannot have a close brace in a varname name: ($varname) [domNode $node asXML]"
					}
					# If the varname isn't alphanumeric+underscore, or is immediately
					# followed by a text sibling whose first character is
					# alphanumeric+underscore, we need to brace quote
					set text_sib	[xpath $node {
						string(following-sibling::*[not(@deleted)][1][name()='text'])
					}]
					if {![regexp {^[0-9A-Za-z_]*$} $varname] || [regexp {^[0-9A-Za-z_]} $text_sib]} {
						set varname "{$varname}"
					}
					append res "\$$varname"
					if {[domNode $node getAttribute type] eq "array"} {
						append res (
						foreach indexnode [xpath $node {*[not(@deleted)][position()>1]}] {
							append res	[reconstitute $indexnode]
						}
						append res )
					}
				}

				syntax {
					#error "syntax: [domNode $node asXML], asText: ([domNode $node asText])"
					#append res [domNode $node asText]
				}

				end {
					set text	[domNode $node asText]
					if {$text ne "\]"} {
						append res $text
					}
				}

				text - space - escape - end - syntax - comment {
					append res [domNode $node asText]
				}

				as {}

				word {
					#if {[domNode $node hasAttribute quoted]} {
					#	switch -exact -- [domNode $node getAttribute quoted] {
					#		brace	{ append res "\u7b" }
					#		quote	{ append res "\"" }
					#	}
					#}
					set dynamic	0
					set need_quotes	0
					set l	[xpath $node { as/*[1] }]
					if {[llength $l] > 0} {
						set as_node	[lindex $l 0]
						set as_type	[domNode $as_node nodeName]
					} else {
						set as_type	""
					}
					switch -exact -- $as_type {
						"" {
							# No parsed interpretation
							set children	[xpath $node { *[not(@noise or @deleted)] }]
							foreach child $children {
								switch -exact -- [domNode $child nodeName] {
									script - var - escape {
										set dynamic	1
									}
									text {}
									as - syntax {}
									default {
										if {![domNode $child hasAttribute value]} {
											error "Unexpected word part type [domNode $child nodeName] with no constant value: [domNode $child asXML]"
										}
									}
								}
							}

							if {!$dynamic} {
								if {[xpath $node {string(@quoted)}] eq "quote"} {
									# Elect to stick with the quoting used in the source, even though no substitutions happen
									set dynamic		1
									set need_quotes	[xpath $node {not(count(*[not(@deleted)])=1 and var[not(@deleted)])}]
								} elseif 0 {
									# Hack to quote html node attrib values with double quotes
									# (for no better reason than that it looks more like html):
									set first_word_val	[xpath $node {string(preceding-sibling::word[not(@deleted)][last()]/@value)}]
									if {[string match <?* $first_word_val]} {
										set wordnum	[xpath $node count(preceding-sibling::word[not(@deleted)])]
										if {$wordnum > 0 && $wordnum % 2 == 0} {
											set dynamic	1
										}
									}
								}
							}

							if {$dynamic} {
								# Need to quote $, [ and \ in text sections
								foreach child $children {
									switch -exact -- [domNode $child nodeName] {
										text {
											set chunk [string map {"\$" "\\\$" "\[" "\\\[" "\\" "\\\\"} [reconstitute $child]]
											if {[regexp {[ \t\f\n\r\v;\]]} $chunk]} {
												set need_quotes	1
											}
											append res	$chunk
										}
										script {
											append res	"\["
											append res	[reconstitute $child]
											append res	"\]"
										}
										default {
											append res	[reconstitute $child]
										}
									}
								}
							} else {
								foreach child $children {
									switch -exact -- [domNode $child nodeName] {
										text {
											append res	[reconstitute $child]
										}
										subexpr {
											# TODO: stop this case from happening - should be collapsed to a text element node here
											append res	[domNode $child getAttribute value]
										}
										as - syntax {}
										default {
											error "Unhandled part in non-dynamic word: [domNode $child nodeName] [domNode $node asXML]"
										}
									}
								}
							}
						}

						script - expr - list {
							set res	[reconstitute $as_node]
						}

						default {
							#if {[domNode $as_node nodeName] eq "script"} {
							#	append res	"\["
							#}
							set res	[reconstitute $as_node]
						}
					}

					# quote word
					if {$dynamic} {
						if {[string index $res 0] in {"\u7b" "\""}} {
							set need_quotes	1
						}
						if {$res eq ""} {
							set need_quotes	1
						}

						if {$need_quotes} {
							set res	\"[string map {"\"" "\\\""} $res]\"
						}
					} else {
						if {[string match "*\\\n*" $res]} {
							# Can't do this because of line continuations
							#set newres [list $res]
							if {
								[regexp {\\+$} $res end_backquotes] &&
								[string length $end_backquotes] % 2 == 1
							} {
								# There are an odd number of \ characters at the end, can't
								# brace quote.  Let [list] take care of it (backslash quoting)
								set newres	[list $res]
							} elseif {![regexp {{|}} $res]} {
								# No open or close brace characters - safe to quote with surrounding braces
								set newres	"{$res}"
							} else {
								# Have to step through $res and count brace depth, with backslash tracking
								set depth	0
								set safe	1
								set reslen	[string length $res]
								for {set i 0} {$i < $reslen} {incr i} {
									switch -exact -- [string index $res $i] {
										"\\" {incr i}
										"\{" {incr depth  1}
										"\}" {incr depth -1}
									}
									if {$depth < 0} {
										set safe	0
										break
									}
								}
								if {$depth > 0} {
									set safe	0
								}

								if {$safe} {
									set newres	"{$res}"
								} else {
									set newres	[list $res]
								}
							}
						} else {
							set newres	[list $res]
							#puts stderr "fast list quote case: ($res) -> ($newres)"
						}
						set res	$newres
					}
					# TODO: handle eofchar somehow, and maybe \0?

					#if {$as_type ne ""} {
					#	#puts stderr "res: $res\n$as_type: [domNode $as_node asXML]"
					#	puts stderr "res: $res\n$as_type"
					#	error "as_type: ($as_type)"
					#}


					if {[domNode $node hasAttribute expand]} {
						set res	"{*}$res"
					}

					#if {[domNode $node hasAttribute quoted]} {
					#	switch -exact -- [domNode $node getAttribute quoted] {
					#		brace	{ append res "\u7d" }
					#		quote	{ append res "\"" }
					#	}
					#}
					#puts stderr "reconstitute word: ->$res<- [domNode $node asXML]"
				}

				default {
					error "Unhandled node type ([domNode $node nodeName])"
				}
			}

			set res
		}

		#>>>
		proc expr_bool value { #<<<
			#puts stderr "expr_bool, value: ($value)"
			set notnum	[catch {::tcl::mathop::+ 0 $value}]
			#puts stderr "notnum: ($notnum)"
			if {$notnum} {
				if {[string is true -strict $value]} {
					#puts stderr "string is true $value"
					return 1
				}
				if {[string is false -strict $value]} {
					#puts stderr "string is false $value"
					return 0
				}
			} else {
				return [::tcl::mathop::!= 0 $value]
			}
			throw {PARSETCL BOOL_INVALID $value} "Value is not a valid boolean: \"$value\""
		}

		#>>>
		proc make_word value { # Emit a word token, properly structured to quote the literal value in $value <<<
			set mini_script		[list list $value]
			set mini_parsetree	[parsetree $mini_script]	;# TODO: ast rather?  idx will be wrong

			# I think you can transplant nodes between docs like this
			# TODO: check
			#puts stderr "make_word ($value):"
			#puts stderr "mini_parsetree: [domNode $mini_parsetree asXML]"
			#puts stderr "dom currentNode: ([dom currentNode])"
			#puts stderr "stolen command word: ([xpath $mini_parsetree {script/command[1]/word[2]}])"
			[dom currentNode] appendChild [lindex [xpath $mini_parsetree {script/command[1]/word[2]}] 0]
		}

		#>>>
		proc replace_command_with_const {node value {valuenode ""}} { #<<<
			#puts stderr "replace_command_with_const \"$value\", command: [domNode $node asXML], parent: [domNode $node parentNode]: [domNode [domNode $node parentNode] asXML]"
			if {$valuenode eq ""} {
				domNode $node appendFromScript {
					set valuenode	[::parsetcl::WORD value $value {::parsetcl::TEXT value $value {::parsetcl::dom::txt $value}}]
				}
			}

			set scriptnode	[lindex [xpath $node {ancestor::script[1]}] 0]
			# TODO: could also be a subexpr or a var node, and not a word node.
			# Make sure this works for that case.
			set wordnode	[domNode $scriptnode parentNode]
			#puts stderr "wordnode: $wordnode: [domNode $wordnode asXML]"
			set commands	[xpath $scriptnode command]

			if {[llength $commands] == 1} {
				# This is the only command in the script:
				# replace the script node with a text node with
				# the value $expr_const_value
				foreach part [xpath $valuenode *] {
					domNode $wordnode insertBefore $part $scriptnode
				}
				domNode $scriptnode setAttribute deleted ""

				# Let the word node handle this itself when we return
				## Check if the wordnode is now constant, and if so fold it up.
				#set const		1
				#set wordvalue	{}
				#foreach child [domNode $wordnode childNodes] {
				#	if {![domNode $child hasAttribute value]} {
				#		set const	0
				#		break
				#	}
				#	append wordvalue	[domNode $child getAttribute value]
				#}
				#if {$const} {
				#	domNode $wordnode setAttribute value $wordvalue
				#}
				return
			}

			# Find this expr command's position in the script
			set idx	[lsearch -exact $commands $node]	;# Not sure if this is safe

			if {$idx == -1} {
				# Shouldn't happen - we couldn't find our
				# own command in the script, but perhaps
				# the above lsearch isn't safe.  Abort
				error "Couldn't find the position of the command to be replaced in its parent script node!"
				return
			}

			if {$idx == [llength $commands]-1} {
				# This command is the last in the script: replace it with {return -level 0 $expr_const_val}
				domNode $scriptnode appendFromScript {
					::parsetcl::COMMAND name "return" {
						::parsetcl::WORD value "return" {::parsetcl::TEXT {::parsetcl::dom::txt return}}
						::parsetcl::SPACE {::parsetcl::dom::txt " "}
						::parsetcl::WORD value "-level" {::parsetcl::TEXT {::parsetcl::dom::txt -level}}
						::parsetcl::SPACE {::parsetcl::dom::txt " "}
						::parsetcl::WORD value "0" {::parsetcl::TEXT {::parsetcl::dom::txt 0}}
						::parsetcl::SPACE {::parsetcl::dom::txt " "}
						make_word $value
					}
				}
				domNode $node setAttribute deleted ""
			} else {
				# This isn't the last command in the script,
				# and nothing receives its return value, so it
				# has no effect, just delete the command.
				domNode $node setAttribute deleted ""
			}
		}

		#>>>
		proc replace_command_with_commands {node commands} { #<<<
			#puts stderr "replace command $node with commands: $commands"
			set parent	[domNode $node parentNode]
			#puts stderr "before [domNode $parent asXML]"
			foreach command $commands {
				if {[domNode $command hasAttribute deleted]} {
					#puts stderr "Replacement command is marked deleted, skipping: [domNode $command asXML]"
					continue
				}
				#puts stderr "Inserting replacement command: [domNode $command asXML]"
				domNode $parent insertBefore $command $node
			}
			domNode $node setAttribute deleted ""
			#puts stderr "after [domNode $parent asXML]"
		}

		#>>>
		proc all_const words { #<<<
			foreach word $words {
				if {![domNode $word hasAttribute value]} {
					return 0
				}
			}
			return 1
		}

		#>>>
		proc simplify {node {cxvar cx}} { #<<<
			upvar 1 $cxvar cx
			# cx contains:
			#	vars:	a dictionary of facts known about variables at this point, (possibly) containing:
			#					- const: the constant's value
			#					- node: the node where the literal value originates (if one exists)
			#	exists:		a dictionary of symbols whose state of existance is known (absence means unknown)
			if {![info exists cx]} {
				set cx	[cx new_cx]
			}

			#puts stderr "simplify: node: ($node)"
			#puts stderr "\tnodeType: ([domNode $node nodeType])"
			#puts stderr "\tnodeName: ([domNode $node nodeName])"
			if {[domNode $node nodeType] ne "ELEMENT_NODE"} {
				# TODO: Rather stop this happening in the first place
				puts stderr "Called simplify on a non-element node"
				return
			}

			if {[domNode $node hasAttribute deleted]} {
				return
			}

			if {[info exists ::_trap] && [apply $::_trap $node]} {
				puts stderr "trap:\n[domNode $node asXML]"
			}

			# Already have a constant value
			if {[domNode $node hasAttribute value]} return

			# Not a contributor to the semantics of the script
			if {[domNode $node hasAttribute noise]} return

			switch -exact -- [domNode $node nodeName] {
				text {
					domNode $node setAttribute value [domNode $node asText]
				}

				escape {
					domNode $node setAttribute value [subst -nocommands -novariables [domNode $node asText]]
				}

				expr {
					set subexpr	[lindex [xpath $node subexpr] 0]
					simplify $subexpr
					if {[domNode $subexpr hasAttribute value]} {
						domNode $node setAttribute value [domNode $subexpr getAttribute value]
					}
					#puts stderr "after simplify expr: [domNode $node asXML]"
				}

				subexpr {
					#puts stderr "Simplify subexpr: [domNode $node getAttribute orig]"
					if {![domNode $node hasAttribute value]} {
						foreach child [xpath $node {*[not(@deleted)]}] {
							simplify $child
						}
						set value	{}
						foreach child [xpath $node {*[not(@deleted)]}] {
							if {![domNode $child hasAttribute value]} {
								return
							}
							append value	[domNode $child getAttribute value]
						}

						domNode $node setAttribute value $value
					}
				}

				operator {
					#puts stderr "Called to simplify operator: [domNode $node asXML]"
					set op		[domNode $node getAttribute name]
					set const	1
					set const_operands	{}
					unset -nocomplain folded
					set operands	[xpath $node subexpr]

					foreach operand $operands {
						simplify $operand
						if {![domNode $operand hasAttribute value]} {
							#puts stderr "simplify operator, no value on operand: [domNode $operand asXML]"
							set const	0
							continue
						}

						set value	[domNode $operand getAttribute value]
						if {$const} {
							lappend const_operands $value
						}
					}

					# Lazy evaluation: don't touch later operands if the result is already determined
					if {[domNode [lindex $operands 0] hasAttribute value]} {
						set value	[domNode [lindex $operands 0] getAttribute value]
						switch -exact -- $op {
							&& {
								if {[expr_bool $value] == 0} {
									set folded	0
								}
							}

							|| {
								if {[expr_bool $value] == 1} {
									#puts stderr "expr_bool($value) is true: [expr_bool $value]"
									set folded	1
								}
							}
						}
					}

					#puts stderr "After simplify operator [domNode [domNode $node parentNode] getAttribute orig]: const: $const, folded: exists: [info exists foled]: ([if {[info exists folded]} {set folded}])"

					if {![info exists folded]} {
						# For && and || eliminate a redundant && 1 / || 0 form, simplifying to the other operand
						unset -nocomplain replacewith
						switch -exact -- $op {
							&& {
								if {[domNode [lindex $operands 0] hasAttribute value] && [expr_bool [domNode [lindex $operands 0] getAttribute value]]} {set replacewith [lindex $operands 1]}
								if {[domNode [lindex $operands 1] hasAttribute value] && [expr_bool [domNode [lindex $operands 1] getAttribute value]]} {set replacewith [lindex $operands 0]}
							}
							|| {
								if {[domNode [lindex $operands 0] hasAttribute value] && ![expr_bool [domNode [lindex $operands 0] getAttribute value]]} {set replacewith [lindex $operands 1]}
								if {[domNode [lindex $operands 1] hasAttribute value] && ![expr_bool [domNode [lindex $operands 1] getAttribute value]]} {set replacewith [lindex $operands 0]}
							}
						}
						if {[info exists replacewith]} {
							set parent			[lindex [xpath $node {ancestor::subexpr[1]}] 0]
							#puts stderr "replacewith Replacing [domNode $parent asXML]\nwith: [domNode $replacewith asXML]"
							set old_children	[xpath $parent {*[not(@deleted)]}]
							foreach child [xpath $replacewith {*[not(@deleted)]}] {
								domNode $parent appendChild $child
							}
							foreach child $old_children {
								domNode $child setAttribute deleted ""
							}
							return
						}
					}

					#puts stderr "const: ($const), op: ($op), info exists folded: ([info exists folded]), folded_val: ([if {[info exists folded]} {set folded}]), const_operands: ($const_operands)"
					if {$const && ![info exists folded]} {
						switch -exact -- $op {
							?  {
								set target	[lindex [xpath $node {ancestor::subexpr[1]}] 0]
								set parent	[domNode $target parentNode]
								if {[lindex $const_operands 0]} {
									set picked	1
								} else {
									set picked	2
									set new	[lindex $operands 2]
									#puts stderr "Replacing ternary ? operator with second alt: \"[lindex $const_operands 2]\" [domNode $new asXML]"
								}
								set new		[lindex $operands $picked]
								set value	[lindex $const_operands $picked]
								#puts stderr "Replacing ternary ? operator with $picked alt: \"$value\" [domNode $new asXML]"
								#puts stderr "Replacing [domNode $parent asXML] with [domNode $new asXML]"
								domNode $parent replaceChild $new $target
								domNode $node setAttribute deleted ""
								domNode $parent setAttribute value $value
								#error "Replaced ternary ? operator: [domNode $parent asXML]"
							}
							&& { set folded [expr {[lindex $const_operands 0] && [lindex $const_operands 1]}] }
							|| { set folded [expr {[lindex $const_operands 0] || [lindex $const_operands 1]}] }

							default {
								if {[llength [info commands ::tcl::mathop::$op]] > 0} {
									set folded	[::tcl::mathop::$op {*}$const_operands]
								} else {
									# TODO: whitelist allowed (side-effect-free) math functions?
									# None of the standard Tcl ones have side effects but users are
									# free to register their own which might have.
									set folded	[::tcl::mathfunc::$op {*}$const_operands]
								}
							}
						}
					}

					if {[info exists folded]} {
						# TODO: replicate the Tcl behaviour of attempting to coerce to an integer, falling back to float, then string?
						set parent	[lindex [xpath $node {ancestor::subexpr[1]}] 0]
						#domNode $parent setAttribute value $folded
						foreach child [domNode $parent childNodes] {
							domNode $child setAttribute deleted ""
						}
						domNode $parent appendFromScript {
							::parsetcl::TEXT value $folded {::parsetcl::dom::txt $folded}
						}
						#if {$folded eq ""} {
						#	set reftree	[parsetree {expr {""}}]
						#	error "folded blank: [domNode $parent asXML], reftree: [domNode $reftree asXML]"
						#}
					}
				}

				word { #<<<
					if {![domNode $node hasAttribute value]} {
						foreach part [xpath $node { *[not(@deleted or @noise or @value)] }] {
							simplify $part
						}
						#puts stderr "word simplifier, after simplify parts: [domNode $node asXML]"
						set value	{}
						foreach part [xpath $node {*[not(@deleted or @noise)]}] {
							switch -exact -- [domNode $part nodeName] {
								text {
									#puts stderr "accumulating part from text node: ([domNode $part asText])"
									append value	[domNode $part asText]
								}
								escape {
									#puts stderr "accumulating part from escape node: ([domNode $part asText]) -> ([subst -nocommands -novariables [domNode $part asText]])"
									append value	[subst -nocommands -novariables [domNode $part asText]]
								}
								default {
									if {![domNode $part hasAttribute value]} {
										# Still no value: part is not a constant
										return
									}
									#error "accumulating part from [domNode $part nodeName]: [domNode $part asXML]"
									#puts stderr "accumulating part from value attrib: ([domNode $node getAttribute value])"
									set value		[domNode $part getAttribute value]
								}
							}
						}

						#puts stderr "accumulated word part values: ($value)"
						# All parts are const, fold the constant up into our
						# @value attrib
						domNode $node setAttribute value $value
						# TODO: merge adjacent text child nodes
					}

					if {[domNode $node hasAttribute value] && [domNode $node hasAttribute expand]} {
						# Our value is known and expand is set, parse the value as
						# a list and replace this word with the resulting words of the list.
						::parsetcl::subparse list $node
						foreach expanded_part [xpath $node { as/list/*[not(@deleted)] }] {
							[$node parentNode] insertBefore $expanded_part $node
						}
						domNode $node setAttribute deleted ""
					}
					#>>>
				}

				var { #<<<
					set type	[domNode $node getAttribute type]
					set varname	[domNode $node getAttribute name]
					switch -exact -- $type {
						scalar {}

						array {
							foreach indexnode [xpath $node { *[not(@deleted)][position()>1] }] {
								simplify $indexnode
							}

							set const	1
							set index	{}
							foreach indexnode [xpath $node { *[not(@deleted)][position()>1] }] {
								if {[domNode $indexnode hasAttribute noise]} continue
								if {![domNode $indexnode hasAttribute value]} {
									set const	0
									break
								}
								append index [domNode $indexnode getAttribute value]
							}

							if {!($const)} {
								# Index isn't const, can't replace
								return
							}

							# This isn't strictly correct - it intrudes on the valid
							# namespace of scalars.  If there is ever a legitimate use
							# case for allowing scalar names that look like arrays,
							# then make this more complicated to accomodate that.
							append varname ($index)
						}
					}

					#puts stderr "looking up constant for $varname: [dict exists $cx vars $varname const]"
					#puts stderr "cx: $cx"
					if {[dict exists $cx vars $varname const]} {
						set value	[dict get $cx vars $varname const]
						domNode $node appendFromScript {
							set new	[::parsetcl::TEXT value $value {::parsetcl::dom::txt $value}]
						}
						set parentNode	[domNode $node parentNode]
						#puts stderr "parentNode: $parentNode: [domNode $parentNode asXML]"
						#puts stderr "new: $new: [domNode $new asXML]"
						#puts stderr "node: $node: [domNode $node asXML]"
						domNode $parentNode replaceChild $new $node
						domNode $node setAttribute deleted ""
						#puts stderr "replaced child: [domNode $parentNode asXML]"
					}
					#>>>
				}

				as { #<<<
					# TODO: perhaps don't do this automatically, but leave it up to
					# the handlers of specific commands that we understand the implications of
					return

					set script_nodes	[xpath $node { script[not(@deleted)] }]
					if {[llength $script_nodes] == 1} {
						# Push the cx
						set saved_cx	$cx
						# TODO: determine somehow whether this script inherits this cx,
						# and how its changes to cx affect ours (if at all).
						simplify [lindex $script_nodes 0]
						set cx	$saved_cx
					}
					#>>>
				}

				command { #<<<
					foreach word [xpath $node { word[not(@deleted)] }] {
						simplify $word
					}

					# List of words may have changed from the loop above, have to refetch
					set words	[xpath $node { word[not(@deleted)] }]

					if {![domNode $node hasAttribute name]} {
						puts stderr "command name is not constant, skipping: [domNode $node asXML]"
						return
					}
					set cmdname	[domNode $node getAttribute name]
					switch -exact -- $cmdname {
						"set" {
							if {[llength $words] < 2 || [llength $words] > 3} {
								throw {PARSETCL SYNTAX_ERROR WRONGARGS} "Wrong number of args to $cmdname"
							}
							switch -exact -- [llength $words] {
								2 {
									# TODO: If we have a value, we could replace this command with the const value,
									# If we could prove that read traces are not in place for it, and that no
									# later commands refer to this variable that we can't replace with consts
								}

								3 {
									cx set_var -varname [lindex $words 1] -value [lindex $words 2]
								}
							}
						}
						"append" {
							if {[llength $words] < 2} {
								throw {PARSETCL SYNTAX_ERROR WRONGARGS} "Too few arguments to $cmdname"
							}
							cx set_var -varname [lindex $words 1] -value [lrange $words 2 end] -append
						}
						"lappend" {
							if {[llength $words] < 2} {
								throw {PARSETCL SYNTAX_ERROR WRONGARGS} "Too few arguments to $cmdname"
							}
							cx set_var -varname [lindex $words 1] -value [lrange $words 2 end] -lappend
						}
						"incr" {
							if {[llength $words] < 2} {
								throw {PARSETCL SYNTAX_ERROR WRONGARGS} "Too few arguments to $cmdname"
							}
							if {[cx const [lindex $words 1] value] && [all_const $words]} {
								incr value {*}[lrange [lmap e $words {domNode $e getAttribute value}] 2 end]
								#puts stderr "Incr new value of [domNode [lindex $words 1] getAttribute value]: ($value): [domNode $node asXML]"
								cx set_var -varname [lindex $words 1] -const $value -provenance "incr" $node
							} else {
								cx set_var -varname [lindex $words 1] -provenance "incr" $node
							}
						}
						"lset" {
							if {[llength $words] < 2} {
								throw {PARSETCL SYNTAX_ERROR WRONGARGS} "Too few arguments to $cmdname"
							}
							if {![domNode [lindex $words 1] hasAttribute value]} {
								cx set_var -varname [lindex $words 1] -provenance "lset element" [lindex $words end]
							} else {
								if {[cx const [lindex $words 1] value]} {
									# Lset value is known
									if {[all_const [lrange $words 2 end]]} {
										# Indices and newval are known
										set lset_args	[lmap e [lrange $words 2 end] {
											domNode $e getAttribute value
										}]
										lset value {*}$lset_args

										cx set_var -varname [lindex $words 1] -const $value -provenance "lset element $lset_args" [lindex $words end]
									} else {
										cx set_var -varname [lindex $words 1] -provenance "lset element" [lindex $words end]
									}
								}
							}
						}
						"unset" {
							set argnodes	[lrange $words 1 end]
							if {[llength $argnodes] > 0} {
								set argval	[domNode [lindex $argnodes 0] getAttribute value]
								if {$argval eq "-nocomplain"} {
									# Pop it off the list
									set argnodes	[lrange $argnodes 1 end]
									set argval	[domNode [lindex $argnodes 0] getAttribute value]
								}
								if {$argval eq "--"} {
									# Pop it off the list
									set argnodes	[lrange $argnodes 1 end]
								}
							}

							foreach varname $argnodes {
								cx unset_var -varname $varname
							}
						}
						"lassign" {
							if {[llength $words] < 2} {
								throw {PARSETCL SYNTAX_ERROR WRONGARGS} "Too few arguments to $cmdname"
							}
							unset -nocomplain listwords
							if {[domNode [lindex $words 1] hasAttribute value]} {
								subparse list [lindex $words 1]
								set listwords	[xpath [lindex $words 1] as/list/word[not(@deleted)]]
							}

							set varname_words	[lrange $words 2 end]
							if {[info exists listwords]} {
								set wordnum	0
								foreach varname_word $varname_words {
									if {$wordnum < [llength $listwords]} {
										cx set_var -varname $varname_word -value $listword -provenance "lassign word $wordnum of" [lindex $words 1]
									} else {
										cx set_var -varname $varname_word -const {} -provenance "lassign beyond end of" [lindex $words 1]
									}
									incr wordnum
								}
							} else {
								set wordnum	0
								foreach varname_word $varname_words {
									cx set_var -varname $varname_word -provenance "lassign word $wordnum of" [lindex $words 1]
									incr wordnum
								}
							}
						}
					}

					if {![all_const $words]} return

					# All the words of this command are constants with known values

					# Watch for commands that set or unset variables and keep our constants cx in sync
					# TODO: increase coverage of commands that can set or unset variables

					# If this variable is bound to another scope (upvar, global, namespace upvar, etc) we have to
					# be careful - we can't know whether it exists or not.  But we still should be able to track
					# constant values it takes during the execution.
					# Update the constants dict.  Maybe include [dict set], [dict unset], [json set], etc here?
					# All of this is only valid if we can somehow prove that nothing is watching this variable
					# with traces, and none of the called commands upvar to it.

					if 0 {
					switch -exact -- $cmdname {
						"unset" { #<<<
							# TODO: This could miss unsets of cx constants
							# if the unset command contains non-const
							# words.  Perhaps we have to watch for this
							# case and disable constant folding in the code
							# that follows it.
							set argnodes	[lrange [xpath $node word] 1 end]
							if {[llength $argnodes] > 0} {
								set argval	[domNode [lindex $argnodes 0] getAttribute value]
								if {$argval eq "-nocomplain"} {
									# Pop it off the list
									set argnodes	[lrange $argnodes 1 end]
									set argval	[domNode [lindex $argnodes 0] getAttribute value]
								}
								if {$argval eq "--"} {
									# Pop it off the list
									set argnodes	[lrange $argnodes 1 end]
								}
							}

							foreach varname_node $argnodes {
								set varname	[domNode $varname_node getAttribute value]
								dict unset cx constants $varname
								dict set cx exists $varname 0
							}
							return
							#>>>
						}
						"incr" { #<<<
							set varname		[xpath $node {string(word[2]/@value)}]
							set words		[xpath $node word]
							if {[llength $words] == 2} {
								set incrval	1
							} elseif {[llength $words] == 3} {
								set incrval [domNode [lindex $words 2] getAttribute value]
							} else {
								throw {PARSETCL SYNTAX_ERROR WRONGARGS} "Too many arguments to $cmdname"
							}

							if {[dict exists $cx constants $varname value]} {
								set prior	[dict get $cx constants $varname value]
							} else {
								set prior	0
							}
							# TODO: complain if either the prior or incval aren't integers
							set next	[+ $prior $incrval]
							dict set cx constants $varname value $next
							dict unset cx constatns $varname node
							dict set cx exists $varname 1
							#>>>
						}
						"append" { #<<<
							set words		[xpath $node word]
							if {[llength $words] < 2} {
								throw {PARSETCL SYNTAX_ERROR WRONGARGS} "Too few arguments to $cmdname"
							}
							set varname		[xpath $node {string(word[2]/@value)}]
							if {
								[llength $words] == 3 &&
								[dict exists $cx exists $varname] &&
								[dict get $cx exists $varname] == 0
							} {
								# This is just an alias for set
								set valuenode	[lindex $words 2]
								dict set cx constants $varname value	[domNode $valuenode getAttribute value]
								dict set cx constants $varname node		$valuenode
								dict set cx exists $varname 1
								return
							}

							if {[dict exists $cx constants $varname value]} {
								set value	[dict get $cx constants $varname value]
							} else {
								set value	{}
							}
							foreach part [lrange $words 2 end] {
								append value [domNode $part getAttribute value]
							}

							dict set cx constants $varname value $value
							dict unset cx constants $varname node
							dict set cx exists $varname 1
							return
							#>>>
						}
						"lappend" { #<<<
							set words		[xpath $node word]
							if {[llength $words] < 2} {
								throw {PARSETCL SYNTAX_ERROR WRONGARGS} "Too few arguments to $cmdname"
							}
							set varname		[xpath $node {string(word[2]/@value)}]
							if {[dict exists $cx constants $varname value]} {
								set value	[dict get $cx constants $varname value]
							} else {
								set value	{}
							}
							foreach newword [lrange $words 2 end] {
								lappend value	[domNode $newword getAttribute value]
							}
							dict set cx constants $varname value $value
							dict unset cx constants $varname node
							dict set cx exists $varname 1
							#>>>
						}
						"lset" { #<<<
							set words		[xpath $node word]
							if {[llength $words] < 2} {
								throw {PARSETCL SYNTAX_ERROR WRONGARGS} "Too few arguments to $cmdname"
							}
							set varname		[xpath $node {string(word[2]/@value)}]
							if {![dict exists $cx constants $varname value]} {
								dict unset cx constants $varname
								dict set cx exists $varname 1
								return
							}
							set value	[dict get $cx constants $varname value]

							set lset_args	{}
							foreach argword [lrange $words 2 end] {
								lappend lset_args	[domNode $newword getAttribute value]
							}
							lset value {*}$lset_args
							dict set cx constants $varname value $value
							dict unset cx constants $varname node
							dict set cx exists $varname 1
							#>>>
						}
						"lassign" { #<<<
							set words	[xpath $node word]
							if {[llength $words] < 2} {
								throw {PARSETCL SYNTAX_ERROR WRONGARGS} "Too few arguments to $cmdname"
							}
							subparse list [lindex $words 1]
							set listwords		[xpath [lindex $words 1] as/list/word]
							set varname_words	[lrange $words 2 end]
							set remain			[lrange $listwords [llength $varname_words] end]
							set matched			[lrange $listwords 0 [expr {[llength $varname_words]-1}]]
							foreach varname_word $varname_words elem $matched {
								set varname	[domNode $varname_word getAttribute value]
								dict set cx constants $varname value	[domNode $elem getAttribute value]
								dict set cx constants $varname node		$elem
								dict set cx exists $varname 1
							}
							# TODO: the result of this command (lassign) is known: the list $remain.  Should we fold it?
							return
							#>>>
						}
					}
					}

					# TODO: is this necessary?
					foreach child [xpath $node word] {
						simplify $child
					}

					switch -exact -- $cmdname {
						"subst" { #<<<
							# This is pure if the substarg is const, parsed, and contains no impure script commands
							# or variable substitutions that aren't known constants.

							set substparts	[xpath $node as/subst/*]
							foreach part $substparts {
								simplify $part
							}
							set value	{}
							foreach part [xpath $node as/subst/*] {
								if {[domNode $part hasAttribute noise]} continue
								if {![domNode $part hasAttribute value]} {
									return
								}
								append value	[domNode $part getAttribute value]
							}

							replace_command_with_const $node $value
							#>>>
						}

						"if" { #<<<
							if 0 {
								set debug	1
							} elseif {![info exists debug]} {
								set debug	0
							}
							try {
							#puts stderr "if simplifier: [domNode $node asXML]"
							if {$debug} {
								puts stderr "if simplifier:\n[reconstitute $node]"
								puts stderr "cx consts:\n\t[join [lmap {v inf} [dict get $cx vars] {
									if {![dict exists $inf const]} continue
									format {%20s = "%s"} $v [dict get $inf const]
								}] \n\t]"
								puts stderr "cx exists:\n\t[join [lmap {v e} [dict get $cx exists] {
									format {%20s = %s} $v $e
								}] \n\t]"
							}

							unset -nocomplain undeterminable
							foreach exprnode [xpath $node {
								word[as/expr]
							}] {
								simplify [lindex [xpath $exprnode as/expr] 0]
								if {![xpath $exprnode {
									boolean(as/expr/subexpr[@value])
								}]} {
									if {$debug} {
										puts "Expression [list [xpath $exprnode string(as/expr/subexpr/@orig)]] isn't constant, can't reduce if"
										puts stderr [domNode $exprnode asXML]
									}
									set undeterminable	1
									break
								}
								if {[expr_bool [xpath $exprnode {
									string(as/expr/subexpr/@value)
								}]]} {
									# Expr is const true, replace if with the next following body
									# TODO: handle "then" if word-1 eq "if"?
									set nodes	[xpath $exprnode {following-sibling::word[as/script][1]}]
									if {[llength $nodes] == 0} {
										error "Cannot find body for const-true condition [list [domNode $exprnode getAttribute value]]"
									}
									set body	[lindex $nodes 0]

									# TODO: adjust the indent
									#puts stderr "true body has script [domNode $body asXML]"
									simplify [lindex [xpath $body as/script] 0]
									if {$debug} {
										puts stderr "expr [list [domNode $exprnode getAttribute value]] is const-true, replacing if with following body: [reconstitute $body]"
									}
									#puts stderr "Replacing if with true body: [domNode $body asXML]"
									set parent	[domNode $node parentNode]
									replace_command_with_commands $node [xpath $body as/script/command]
									#if {$debug} {puts stderr "After replace: [domNode $parent asXML]"}
									return
								}
							}

							if {[info exists undeterminable]} {
								if {$debug} {puts stderr "Couldn't resolve non-constant if condition"}
								# Couldn't reduce to a known body, but still
								# descend into each script argument and simplify it:
								foreach bodyword [xpath $node word/as/script] {
									cx on varchange name {
										puts stderr "If tainting $name"
										if {[dict exists $cx var $name]} {
											dict unset cx var $name const
										}
										dict unset cx exists $name
									} {
										simplify $bodyword
										# TODO: compose the branch cx with the parent:
										#	- constants with different existence values are removed from exists
										#	- constants with different values are unset (perhaps track that they can take multiple values, and the conditions for each?)
									}
								}
								if {$debug} {
									puts stderr "simplified if bodies:\n[reconstitute $node]"
									puts stderr "cx consts after:\n\t[join [lmap {v inf} [dict get $cx vars] {
										if {![dict exists $inf const]} continue
										format {%20s = "%s"} $v [dict get $inf const]
									}] \n\t]"
									puts stderr "cx exists after:\n\t[join [lmap {v e} [dict get $cx exists] {
										format {%20s = %s} $v $e
									}] \n\t]"
								}
							} else {
								# All conditions are const-false, replace with the else body if present
								if {$debug} {puts stderr "All conditions are const-false, looking for else body"}
								set last_word	[lindex [xpath $node word] end]
								if {$last_word ne ""} {
									set last_expr	[xpath $last_word {preceding-sibling::word[as/expr][1]}]
									set nodes	[xpath $last_expr {following-sibling::word[as/script][2]}]
									if {[llength $nodes] == 0} {
										if {$debug} {puts stderr "No else body found"}

										domNode $node setAttribute deleted ""
										#domNode $node delete
									} else {
										set body	[lindex $nodes 0]
										if {$debug} {puts stderr "Resolved else body: [domNode $body asXML]"}
										if {[xpath $body {boolean(as/script)}]} {
											# TODO: adjust the indent
											#puts stderr "true body has script [domNode $body asXML]"
											simplify [lindex [xpath $body as/script] 0]
											if {$debug} {puts stderr "Replacing if with else body: [domNode $body asXML]"}
											set parent	[domNode $node parentNode]
											replace_command_with_commands $node [xpath $body as/script/command]
											#puts stderr "After replace: [domNode $parent asXML]"
										}
									}
								}
							}
							} on return {r o} {
								#dict set o -code return
								return -options $o $r
							} finally {
								unset -nocomplain debug
							}
							#>>>

							#error "after if simplifier:\n[reconstitute $node]"
						}

						"for" { #<<<
							simplify [xpath [lindex $words 1] as/script]	;# Initial conditions
							cx on varchange name {
								# Have to give up on what we know about any var that is changed
								# in the end expression or post-iteration script.
								# For the loop body, we can't know if it will be evaluated even
								# once, and therefore any variables it can change are undefined.
								if {[dict exists $cx var $name]} {
									dict unset cx var $name const
								}
								dict unset cx exists $name
							} {
								simplify [xpath [lindex $words 2] as/expr] ;# End-test expression
								simplify [xpath [lindex $words 3] as/script] ;# Post-iteration script
								simplify [xpath [lindex $words 4] as/script] ;# Loop body
							}
							#>>>
						}

						"while" { #<<<
							simplify [xpath [lindex $words 1] as/expr]	;# while expression

							if {[xpath $node {
								boolean(word[1]/as/expr/subexpr[@value])
							}]} {
								if {![expr_bool [xpath $node {string(word[1]/as/expr/subexpr/@value)}]]} {
									# Expression is constant false, remove the while
									domNode $node setAttribute deleted ""
									return
								}
							}

							cx on varchange name {
								# For the loop body, we can't know if it will be evaluated even
								# once, and therefore any variables it can change are undefined.
								if {[dict exists $cx var $name]} {
									dict unset cx var $name const
								}
								dict unset cx exists $name
							} {
								simplify [xpath [lindex $words 2] as/script]
							}
							#>>>
						}

						"foreach" - "lmap" { #<<<
							cx on varchange name {
								if {[dict exists $cx var $name]} {
									package require tty
									puts stderr [tty colour red {return -level 0 "foreach tainting $name"}]
									dict unset cx var $name const
								}
								dict unset cx exists $name
							} {
								set iterators	[lrange $words 1 end-1]
								# TODO: what about expanded words?
								foreach {varlist iterator_source} $iterators {
									if {[xpath $varlist {
										boolean(
											not(as/list) or
											as/list/word[not(@value)]
										)
									}]} {
										package require tty
										puts stderr [tty colour red {return -level 0 "foreach tainting everything: [domNode $varlist asXML]"}]
										# Some variables' names are dynamic, have to throw out everything
										dict set cx vars		{}
										dict set cx exists		[dict filter $cx value 1]	;# Can't know if this set a previously unset variable, but we can keep knowledge about any definitely set variables
										if {[info exists value]} {
											dict set cx unresolved_vars $varname nodes $value
										}
										break
									} else {
										foreach varname_word [xpath $varlist /as/list/word] {
											cx set_var -varname $varname_word -provenance "foreach iterator over" $iterator_source
										}
									}
								}

								simplify [xpath [lindex $words end] as/script]
							}

							#>>>
						}

						"expr" { #<<<
							if {[xpath $node {boolean(count(word)=2 and word[2]/as/expr)}]} {
								simplify [lindex [xpath $node {word[2]/as/expr/subexpr}] 0]
								set expr_const_node		[xpath $node {word[2]/as/expr/subexpr}]
								if {[domNode $expr_const_node hasAttribute value]} {
									set expr_const_value	[domNode $expr_const_node getAttribute value]
									set parent	[domNode $node parentNode]
									replace_command_with_const $node $expr_const_value $expr_const_node
								}
							}
							#>>>
						}

						"proc" { #<<<
							set old_cx	$cx
							set cx	[cx new_cx]
							set words	[xpath $node {word[4]/as/script}]
							#puts stderr "Descending into proc body: [lindex $words 0]: [domNode [lindex $words 0] asXML]"
							simplify [lindex $words 0]
							set cx	$old_cx
							#>>>
						}

						"parse_args" { #<<<
							# TODO: update the cx state with vars known to exist (-required and -boolean)

							#>>>
						}

						default {
							set words	[xpath $node word]

							# Check that the command (which may be an ensemble) is
							# in a whitelist of pure functions (side effect free):
							switch -exact -- $cmdname {
								llength - list - lindex - lrange - linsert - lsearch - lsort - lreplace - concat - join -
								format {}

								binary { #<<<
									if {[llength $words] < 2} return
									set subcommand	[lindex $words 1]
									if {![domNode $subcommand hasAttribute value]} return	;# Not a static subcommand
									set subcommand_text	[domNode $subcommand getAttribute value]
									switch -exact -- $subcommand_text {
										format - encode - decode {
											# format / encode / decode are pure
										}

										scan {
											# scan could be replaced by variable
											# sets of constant values (though this
											# may not be a win, and make quoting
											# the literal values a pain.  Still,
											# the bytecode compiler may be able to
											# do good things with the result)
											return
										}

										default {
											return
										}
									}
									#>>>
								}

								clock { #<<<
									if {[llength $words] < 2} return
									set subcommand	[lindex $words 1]
									if {![domNode $subcommand hasAttribute value]} return	;# Not a static subcommand
									set subcommand_text	[domNode $subcommand getAttribute value]
									switch -exact -- $subcommand_text {
										add - format - scan {
											# These are pure, up to the timezone /
											# leap time definitions changing (which
											# amounts to a change of their
											# implementation, so I'm inclined to
											# call them pure)
										}
										default return
									}
									#>>>
								}

								string {
									# TODO: maybe don't replace [string range] with a large repeat value?
								}

								info { #<<<
									if {[llength $words] < 2} return
									set subcommand	[lindex $words 1]
									if {![domNode $subcommand hasAttribute value]} return	;# Not a static subcommand
									set subcommand_text	[domNode $subcommand getAttribute value]
									switch -exact -- $subcommand_text {
										exists {
											# info exists is pure if the existence of the var it is checking is known
											# at compile time.
											set varname	[domNode [lindex $words 2] getAttribute value]
											if {[dict exists $cx exists $varname]} {
												replace_command_with_const $node [dict get $cx exists $varname]
											}
											return
										}
										default return
									}
									#>>>
								}

								dict { #<<<
									if {[llength $words] < 2} return
									set subcommand	[lindex $words 1]
									if {![domNode $subcommand hasAttribute value]} return	;# Not a static subcommand
									set subcommand_text	[domNode $subcommand getAttribute value]
									switch -exact -- $subcommand_text {
										get - create - exists - keys - merge - replace - size - values {}

										for {
											# This is pure in the sense that it can be unrolled with the iteration variables
											# replaced with constants in each iteration body instance, and that body simplified,
											# but should we?
											return
										}

										filter {
											if {[llength $words] < 4} return
											set filtertype	[lindex $words 3]
											if {![domNode $filtertype hasAttribute value]} return	;# Not a static filtertype
											set subcommand_text	[domNode $filtertype getAttribute value]
											if {$subcommand_text ni {key value}} {
												# Not a case that is known to be pure (currently only "script")
												# TODO: if we can prove the script pure (in terms of the known constants, its iterator variables), allow it here?
												return
											}
										}

										default {
											# Not a (known) pure function - we can't reduce it here
											return
										}
									}
									#>>>
								}

								json { #<<<
									if {[llength $words] < 2} return
									set subcommand	[lindex $words 1]
									if {![domNode $subcommand hasAttribute value]} return	;# Not a static subcommand
									set subcommand_text	[domNode $subcommand getAttribute value]
									switch -exact -- $subcommand_text {
										get - extract - exists - string - number - boolean -
										object - array - bool - normalize - pretty - isnull -
										type - length - keys - decode - valid {}

										template {
											# TODO: this is pure, but only if supplied a dictionary for the subst values, or
											# if all of the subst source vars are compile-time-known constants
											return
										}

										foreach - lmap - amap - omap {
											# This is pure in the sense that it can be unrolled with the iteration variables
											# replaced with constants in each iteration body instance, and that body simplified,
											# but should we?
											return
										}

										filter {
											if {[llength $words] < 4} return
											set filtertype	[lindex $words 3]
											if {![domNode $filtertype hasAttribute value]} return	;# Not a static filtertype
											set subcommand_text	[domNode $filtertype getAttribute value]
											if {$subcommand_text ni {key value}} {
												# Not a case that is known to be pure (currently only "script")
												# TODO: if we can prove the script pure (in terms of the known constants, its iterator variables), allow it here?
												return
											}
										}

										default {
											# Not a (known) pure function - we can't reduce it here
											return
										}
									}
									#>>>
								}

								for - while - foreach - lmap { #<<<
									# These is pure in the sense that they can be
									# unrolled with the iteration variables
									# replaced with constants in each iteration
									# body instance, and that body simplified, but
									# should we?
									return
									#>>>
								}

								default {
									# TODO: if this is a known proc (that we have parsed), attempt to simplify it given its
									# constant args - if the result is a constant fold or eliminate it.

									# This isn't a (known) pure function - we can't reduce it here
									return
								}
							}

							# TODO: check that there are no command or execution
							# traces on this command before we replace it.

							# This is a whitelisted pure function: replace the
							# command with its evaluation (now) given its constant
							# arguments.

							set cmd	[lmap word [xpath $node word] {
								domNode $word getAttribute value
							}]
							#error "command reduction $cmd: [{*}$cmd]"
							puts stderr "simplify replacing $node ([domNode $node asXML]) with result of [list {*}$cmd]"
							replace_command_with_const $node [{*}$cmd]
						}
					}
					#>>>
				}

				end {}

				default { #<<<
					foreach child [xpath $node *] {
						#puts stderr "Simplifying (default): [domNode $child nodeName]"
						simplify $child
					}
					#>>>
				}
			}
		}

		#>>>
		proc indent {node orig} { #<<<
			#domNode $node ownerDocument doc
			#set linestarts	[xpath $node {string(//script[1]/@linestarts)}]
			set linestarts	[lmap e [regexp -all -indices -inline \n $orig] {lindex $e 0}]
			#puts stderr "   linestarts: $linestarts"
			#puts stderr "doclinestarts: [xpath $node {string(//script[1]/@linestarts)}]"
			set lines	[split $orig \n]
			if 0 {
				# Annotate each command with its indent (script nesting) level:
				foreach command [xpath $node //command] {
					set space	[xpath $command {string(preceding-sibling::space[1])}]
					if {![string match *\n* $space]} {
						set end	[xpath $command {string(preceding-sibling::command[1]/end)}]
						set leading_space	$end$space
					} else {
						set leading_space	$space
					}
					set nesting	[xpath $command {
						count(ancestor::word[as/script or as/expr])
					}]
					incr nesting
					set idx		[domNode $command getAttribute idx]
					set len		[domNode $command getAttribute len]
					set line	[expr {[lsearch -sorted -increasing -bisect -integer $linestarts $idx]+1}]
					set chunk	[regsub {\n.*$} [string range $orig $idx $idx+$len] {}]

					if {[domNode $command hasAttribute name]} {
						set cmd	[domNode $command getAttribute name]
					} else {
						set cmd	[reconstitute [xpath $command {word[1]}]]
					}
					if {[xpath $command {
						boolean(
							preceding-sibling::*[1 and name()="space"]
						)
					}]} {
						set spacenode	[xpath $command {preceding-sibling::space[1]}]
						domNode $spacenode setAttribute deleted ""
						domNode $command setAttribute indent \n($nesting)[string repeat \t $nesting]
						#puts "space node:	[domNode [xpath $command {preceding-sibling::space[1]}] asXML]"

					} else {
						set msg "No preceding space found for [domNode $command asXML]"
						set nodes	[xpath $command {preceding-sibling::*[1]}]
						if {[llength $nodes]} {
							append msg	": [domNode [lindex $nodes 0] asXML]"
							error $msg
						} else {
							# no preceding sibling found
						}
					}
					#puts "command ($cmd), nesting: $nesting, own line: [string match *\n* $leading_space], idx: $idx, len: $len, line: $line, ([lindex $lines $line]), ($chunk)"
				}
				#puts stderr "HEAD:\n[string range [domNode $node asXML] 0 1000]"
			} else {
				# Annotate each word[as/script or as/expr or as/list] with its nesting level
				set base	1
				#domNode $node setAttribute indent $base
				puts "NODE ($node)"
				try {
					puts "has indent? [domNode $node hasAttribute indent]"
				} on error {errmsg options} {
					puts stderr "Error attempting to indent $node: $errmsg\n$options"
					return
				}
				domNode [xpath $node {/tcl/script[not(@deleted)][1]}] setAttribute indent $base
				puts "Found: [xpath $node {
					count(
						//word/as/script |
						//word/as/expr |
						//word/as/list
					)
				}] in [string range [domNode $node asXML] 0 1024]"
				foreach wordnode [xpath $node {
					//word/as/script |
					//word/as/expr |
					//word/as/list
				}] {
					set nesting	[expr {$base + [xpath $wordnode {
						count(ancestor::word[as/script or as/expr or as/list])
					}]}]
					if 0 {
						set outer	[xpath $wordnode {string(ancestor::*/@indent[1])}]
						set nesting	[expr {$outer+1}]
					}
					domNode $wordnode setAttribute indent $nesting
				}
			}
		}

		#>>>
		proc macro {body args} { #<<<
			set orig	[string range " $body" 1 end]
			parse_args $args {
				-notset		{-default {} -# {List of variables known not to exist}}
				args		{-name consts}
			}
			set tree	[parsetree $body]
			cx new_cx

			foreach var $notset {
				dict set cx exists $var 0
			}
			dict for {name val} $consts {
				dict set cx vars $name const $val
				dict set cx exists $name 1
			}

			if {0 && [dict exists $consts optname] && [dict get $consts optname] eq "-server"} {
				package require tty
				puts [tty colour yellow {
					set out	""
					#foreach command [xpath $tree {//var[@name="handlers"]/ancestor::command[1]}] {
					#	append out [domNode $command asXML]
					#	set found	1
					#}
					append out "consts: [list $consts], notset: [list $notset], body: [list $body]"
					set out
				}]
				set ::_trap [list node {
					upvar 1 cx cx  debug debug
					if {[::parsetcl::xpath $node {boolean(
						self::command[@name="if"]
					)}]} {
						if {[string match *_type* [xpath $node {string(word[2]/@value)}]]} {
							puts "XXX if simplifier ([xpath $node {string(word[2]/@value)}]):\n[reconstitute $node]"
							set debug 1
						}
						return 0
					}
					return 0
				} [namespace current]]
			}
			if 0 {
			package require tty
			set found	0
			puts [tty colour yellow {
				set out	""
				foreach command [xpath $tree {//var[@name="handlers"]/ancestor::command[1]}] {
					append out [domNode $command asXML]
					set found	1
				}
				set out
			}]
			if {$found} {
				puts "body:\n$body"
				set ::_trap {node {
					set hit	[xpath $node {boolean( self::command[word/var[@name="handlers"]] )}]
					#set hit	[xpath $node {boolean( self::command[@name="switch"] )}]
					if {$hit} {
						puts stderr "command: [xpath $node string(@name)]"
						set ::_trap	{node {
							xpath $node { boolean( self::var[@name="handlers"] ) }
						} ::parsetcl}
					}
					return 0
				} ::parsetcl}
				if {[dict exists $consts handlers]} {
					#puts stderr "macro [list $body], consts: [list $consts]"
					#error "cx: $cx"

				}
			}
			}

			simplify $tree

			if 0 {
			foreach deleted [xpath $tree {//*[@deleted]}] {
				catch {
					domNode $deleted delete
				}
			}
			}
			if 0 {
			puts [tty colour bright cyan {
				set out	""
				foreach command [xpath $tree {//var[@name="handlers"]/ancestor::command[1]}] {
					append out [domNode $command asXML]
				}
				set out
			}]
			}

			indent $tree $orig

			set res	[reconstitute $tree]
			if {[info exists ::_trap]} {
				puts [tty colour bright cyan {
					set out	""
					append out $res
					#foreach command [xpath $tree {//var[@name="handlers"]/ancestor::command[1]}] {
					#	append out [domNode $command asXML]
					#}
					set out
				}]
			}

			unset -nocomplain ::_trap
			set res
		}

		#>>>
		proc compile_parse_args {passed argspec} { #<<<
			# Build a lambda that takes the parsed argwords passed to a command and
			# returns the known local variable state that results

			set compile_args_body [subst {
				set cx	[list [cx new_cx]]
			}]

			set required_opts	{}
			set default_opts	{}
			set specnum			0
			set opt_positional	{}
			unset -nocomplain opt_args
			foreach {name spec} $argspec {
				incr specnum

				parse_args $spec {
					-default	{}
					-required	{-boolean}
					-validate	{}
					-name		{}
					-boolean	{-boolean}
					-args		{-default 1 -name argcount}
					-enum		{}
					-#			{}
					-multi		{}
					-alias		{}
				} specparams
				set notset		{}

				if {[string index $name 0] eq "-"} {
					dict set specparams _type	named
				} elseif {$name eq "args" && $specnum == [llength $argspec]/2} {
					dict set specparams _type	args
				} else {
					dict set specparams _type	positional
				}

				if {![dict exists $specparams name]} {
					if {[string index $name 0] eq "-"} {
						dict set specparams name	[string range $name 1 end]
					} else {
						dict set specparams name	$name
					}
				}

				if {[dict get $specparams required]} {
					lappend required_opts	$name 1
				}

				if {[dict exists $specparams multi]} {
					if {[dict exists $specparams default]} {
						dict set default_opts [dict get $specparams multi] $name
					}
				} else {
					if {[dict exists $specparams default]} {
						dict set default_opts $name [dict get $specparams default]
					} elseif {[dict get $specparams boolean] || [dict get $specparams argcount] == 0} {
						dict set default_opts $name 0
					}
				}

				foreach v {
					default
					required
					validate
					name
					boolean
					args
					enum
					#
					multi
					alias
				} {
					if {![dict exists $specparams $v]} {
						lappend notset $v
					}
				}

				set argspec_handler { #<<<
					unset -nocomplain outval

					if {[info exists multi]} {
						set outname 	$multi
						set outval		$name
						set outnodes	[list $argnode]
					} else {
						set outname 	$name
					}

					while 1 {
						puts stderr "vars: [info vars]"
						if {$boolean || $argcount == 0} {
							set outval		1
							set outnodes	{}	;# TODO: what?
						} else {
							if {$_type in {positional args}} {
								# $i already points at the first value, step it
								# back so that it matches the named param state
								incr i -1
							}
							if {$_type eq "args"} {
								set argcount	[expr {$arglen - $i - 1}]
								if {$argcount == 0 && $required} {
									error "No arguments remain for args"
								}
							} else {
								if {$arglen - $i - 1 < $argcount} {
									if {$_type eq "positional" && [info exists default]} {
										# TODO: default values are not required to pass validation / enum membership
										set outval	$default
										break
									}
									error "Too few arguments remain for $optname"
								}
							}
							if {$argcount == 1 && $_type ne "args"} {
								set argnode		[lindex $args [incr i]]
								set outnodes	[list $argnode]
								if {[domNode $argnode hasAttribute value]} {
									set outval	[domNode $argnode getAttribute value]
								}
							} else {
								# _type "args" always gets a list, even if argcount=1
								set outval		{}
								set outnodes	{}
								for {set j 0} {$j < $argcount} {incr j} {
									set argnode			[lindex $args [incr i]]
									lappend outnodes	$argnode
									if {[domNode $argnode hasAttribute value]} {
										if {[info exists outval]} {
											lappend outval	[domNode $argnode getAttribute value]
										}
									} else {
										# Not a constant
										unset -nocomplain outval
									}
								}
							}
						}
						break
					}

					dict set cx vars $outname nodes $outnodes
					if {[info exists outval]} {
						dict set cx vars $outname const $outval
					}
					dict set cx exists $outname 1

					dict unset required_opts $name

					if {[info exists outval]} {
						if {[info exists validate]} {
							# Might not be valid to run this at compile-time: could call custom procs in the project
							# that aren't loaded here
							try {
								{*}$validate $outval
							} on error {errmsg options} {
								error "arg $optname ($outval) fails validation with error: $errmsg"
							} on ok res {
								if {!($res)} {
									error "arg $optname ($outval) fails validation: $res"
								}
							}
						}

						if {[info exists enum]} {
							if {$outval ni $enum} {
								error "arg $optname ($outval) is not one of the valid choices: [join $enum {, }]"
							}
						}
					}

					#>>>
				}

				switch -exact -- [dict get $specparams _type] {
					named {
						append handlers {
						} [list $name] { } [list [macro $argspec_handler -notset $notset optname $name {*}$specparams]] \n
					}
					positional {
						lappend opt_positional	[macro $argspec_handler -notset $notset optname $name {*}$specparams]
					}
					args {
						set opt_args			[macro $argspec_handler -notset $notset optname $name {*}$specparams]
					}
					default {
						error "Unhandled _type \"[dict get $specparams _type]\""
					}
				}
			}

			append handlers {
						-- {
							# End of options
							incr i
							break
						}
						default {
							# Didn't match any of our options - assign to the first positional tail param
							break
						}
			}

			set options_loop { #<<<
				set req_opts	$required_opts

				dict for {name val} $default_opts {
					dict set cx vars $name const $val
					dict set cx exists 1
				}

				# Named arguments phase <<<
				set argslen	[llength $args]
				for {set i 0} {$i < $argslen} {incr i} {
					set argnode	[lindex $args $i]
					if {![domNode $argnode hasAttribute value]} {
						puts stderr "Saw dynamic arg where an option was expected, can't resolve later args mappings: [domNode $argnode asXML]"
						break
					}
					switch -exact -- [domNode $argnode getAttribute value] $handlers
				}
				set args	[lrange $args $i end]
				set i		0

				#>>>
				# Positional arguments phase <<<
				foreach handler $opt_positional {
					set argval	[lindex $args $i]; incr i
					eval $handler
				}
				set args	[lrange $args $i end]
				set i		0

				#>>>
				# Variadic arguments phase <<<
				if {[info exists opt_args]} {
					eval $opt_args
				}
				set args	[lrange $args $i end]
				set i		0

				#>>>
				if {[llength $args]} { # Produce error for too many args <<<
					error "Too many arguments: [join [lmap a $args {
						if {[domNode $a hasAttribute value]} {
							set val	[domNode $a getAttribute value]
							if {[string length $val] > 40} {
								set val	[string range $val 0 39]\u2026
							}
						} else {
							set val	"Dynamic: [join [lmap p [xpath $a *] {
								set type	[domNode $p nodeName]
								set detail	[reconstitute $p]
								switch -exact -- $type {
									var {}
									script {
										if {[string length $detail] > 40} {
											set detail	[string range $val 0 39]\u2026]
										}
									}
									default {
										if {[string length $detail] > 40} {
											set detail	[string range $val 0 39]\u2026
										}
									}
								}
								format {%s: %s} $type $detail
							}] {, }]"
						}
						set val
					}] {, }]"
				}

				#>>>
				if {[dict size $req_opts]} { # Produce error for missing required args <<<
					error "Missing required options: [join [dict keys $req_opts] {, }]"
				}

				#>>>

				set cx
				#>>>
			}

			set extra	{}
			if {[info exists opt_args]} {
				lappend extra opt_args $opt_args
			}
			append compile_args_body [macro $options_loop \
				default_opts	$default_opts \
				required_opts	$required_opts \
				handlers		$handlers \
				opt_positional	$opt_positional \
				{*}$extra]

			set compile_args [list args $compile_args_body]
		}

		#>>>
		proc format_tcl script { #<<<
			set orig	[string range " $script" 1 end]
			set node	[parsetree [string range "$script " 0 end-1]]
			indent $node $orig
			package require tty
			tty colour red {reconstitute $node}
		}

		#>>>
	}

	namespace path {
		::tclreadline
		helpers
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

				puts stderr "Would complete ($text) for parse_args spec, with ($parseargs_input) input"
				# TODO: parse $body with parsetcl and find parse_args argspec, then feed the $parseargs_input into an assigner that consumes it to match the parse_args argspec, and then present choices for the context word that is being completed (either an option, or a value for an option)
				package require parsetcl

				set ast	[parsetcl ast $body]
				#puts stderr "ast:\n[domNode $ast asXML]"
				set parseargs_cmds	[parsetcl xpath $ast {
					//command[
						(
							@name='parse_args' or
							@name='::parse_args::parse_args' or
							@name='parse_args::parse_args'
						) and
						word[2 and count(*)=1]/var[@name='args'] and
						word[3 and @value]
					]
				}]
				puts stderr "parseargs_cmds: $parseargs_cmds"
				switch -exact -- [llength $parseargs_cmds] {
					0 {
						puts stderr "Couldn't find parse_args command:\n[domNode $ast asXML]"
						return ""
					}

					1 {
						set spec	[parsetcl xpath [lindex $parseargs_cmds 0] {string(word[3]/@value)}]
						puts stderr "Got parseargs spec: $spec"
						#compile_parse_args $parseargs_input $spec
						#puts stderr "compile_parse_args:\n[format_tcl [compile_parse_args $parseargs_input $spec]]"
						puts stderr "compile_parse_args:\n[compile_parse_args $parseargs_input $spec]"
						return ""
					}

					default {
						puts stderr "Multiple parse_args calls found:\n[join [lmap e $parseargs_cmds {domNode $e asXML}] \n]"
						return ""
					}
				}
			} on error {errmsg options} {
				puts stderr "Couldn't parse $cmd as a proc: [dict get $options -errorinfo]"
				return ""
			}
		} on error {errmsg options} {
			puts stderr "Unhandled error in completer: [dict get $options -errorinfo]"
		}
		return ""
	}

	#>>>
}
} on error {errmsg options} {
	puts stderr "Error loading tclreadline::complete::ensemble [dict get $options -errorcode]: $errmsg\n[dict get $options -errorinfo]"
	return -options $options $errmsg
}
# vim: ft=tcl ts=4 shiftwidth=4 foldmethod=marker foldmarker=<<<,>>>
