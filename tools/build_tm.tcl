#!/usr/bin/env tclsh
# Wrapper that produces the .tm tree under $builddir. Called from
# meson's custom_target; it does the two things the Makefile used to do
# (copy aws.tcl into aws-VER.tm, then run build.tcl to generate the
# per-service modules) in a form that meson can depend on.
#
# Subproject dependency discovery: meson passes dependency build dirs
# through the TCLLIBPATH env var (space-separated). TCLLIBPATH on its
# own is enough for traditional packages (Tcl auto-loads it into
# auto_path at startup), but .tm modules need tcl::tm::path. build.tcl
# honors AWSTCL_EXTRA_TM_PATH (colon-separated) for tm::path; we
# synthesise that from TCLLIBPATH below so build.tcl finds both kinds
# of package under subprojects/*/build9g/.

package require Tcl 8.6-

proc getopt {argsvar key {default ""}} {
	upvar 1 $argsvar args
	set idx [lsearch -exact $args $key]
	if {$idx < 0} {return $default}
	set v [lindex $args [expr {$idx + 1}]]
	set args [lreplace $args $idx [expr {$idx + 1}]]
	return $v
}

set tclsh       [getopt argv --tclsh]
set version     [getopt argv --version]
set source_dir  [getopt argv --source]
set build_dir   [getopt argv --builddir]
set definitions [getopt argv --definitions]
set mode        [getopt argv --mode]

foreach need {tclsh version source_dir build_dir definitions mode} {
	if {[set $need] eq ""} {
		puts stderr "build_tm.tcl: missing required option --$need"
		exit 2
	}
}

# Master .tm: verbatim copy of aws.tcl. Written to a temp path first so
# concurrent readers (e.g. a devenv shell that already has the file open)
# don't see a partial write, then renamed.
set master_src [file join $source_dir aws.tcl]
set master_dst [file join $build_dir aws-$version.tm]
file mkdir [file join $build_dir aws]
# Custom-target output dir may not exist yet when meson invokes us —
# custom_target auto-creates the exact output's parent but not arbitrary
# siblings, so `mkdir -p` equivalent for the aws/ subtree is still our
# responsibility (handled above).
set tmp $master_dst.new
file copy -force $master_src $tmp
file rename -force $tmp $master_dst

# Per-service modules: run build.tcl with -prefix pointing at the build
# dir so its writes land alongside the master file. We invoke the
# detected tclsh explicitly so the build environment uses the same
# interpreter meson validated. TCLLIBPATH and AWSTCL_EXTRA_TM_PATH are
# set by meson's env passing (see meson.build — they carry subproject
# build dirs for traditional and .tm packages respectively).

set build_script [file join $source_dir build.tcl]
set rc [catch {
	exec $tclsh $build_script \
		-ver $version \
		-$mode \
		-definitions $definitions \
		-prefix $build_dir \
		>@ stdout 2>@ stderr
} errmsg]
if {$rc} {
	puts stderr "build.tcl failed: $errmsg"
	exit 1
}

