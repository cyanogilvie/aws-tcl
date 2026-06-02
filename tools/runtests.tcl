#!/usr/bin/env tclsh
# Drive tests/all.tcl with the just-built package loaded from the build
# dir rather than whatever Tcl module lookup would pick up from the
# system. Invoked as meson test('tcltest', ...) — see tests/meson.build.
#
# Args:
#   argv0 = source_root (where tests/ lives)
#   argv1 = build_dir   (where aws-VER.tm and aws/*.tm live)

set argv	[lassign $argv source_root build_dir]

if {[info exists env(TESTFLAGS)]} {
    lappend argv {*}$env(TESTFLAGS)
}
if {"-singleproc" ni $argv} {lappend argv -singleproc 1}

if {$source_root eq "" || $build_dir eq ""} {
	puts stderr "runtests.tcl: usage: runtests.tcl <source_root> <build_dir>"
	exit 2
}

# A .tm file named aws-X.Y.tm in a tcl::tm path directory is auto-
# discovered by package require. We add the build dir so the test
# interpreter picks up the just-built aws-VER.tm and its sibling
# aws/ subtree.
# tcltest's initial package scan registers `package ifneeded` entries
# against whatever tm paths are active when tcltest itself is loaded —
# i.e., before -load runs. That means prepending our build dir here
# wouldn't change the resolved source file for aws/aws::*. We also
# can't blanket `package forget` on every test-file load (that would
# re-source aws.tcl each time and double-register its singletons).
# Drop the stale entries once, the first time this script is invoked
# — subsequent calls are no-ops because aws is already `provide`d.
#
# The -load block also pulls subproject build dirs (from TCLLIBPATH /
# TCLX_Y_TM_PATH) into tcl::tm::path so the test interp finds .tm-format deps
# (chantricks, rl_http) from the build tree when they aren't system-installed.
set loadarg [list apply {build_dir {
	tcl::tm::path add $build_dir
	if {![info exists ::_awstcl_path_primed]} {
		foreach pkg [package names] {
			if {$pkg eq "aws" || [string match aws::* $pkg]} {
				package forget $pkg
			}
		}
		set ::_awstcl_path_primed 1
	}
}} $build_dir]

set argv	[list -load $loadarg {*}$argv]

# Make [info script] / $argv0 look like the test script was invoked
# directly, so any relative-path idioms in it keep working.
source [file join $source_root tests/all.tcl]
