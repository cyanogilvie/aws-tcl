package forget aws
catch {namespace delete ::aws}
tcltest::loadTestedCommands
package require aws
package require rl_json
package require rltest

proc readfile fn {
	set h	[open $fn r]
	try {read $h} finally {close $h}
}

interp alias {} json {} ::rl_json::json

# vim: ft=tcl foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
