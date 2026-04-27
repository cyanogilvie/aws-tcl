#!/usr/bin/env tclsh
# Post-build install step: copy the per-service .tm tree from
# $builddir/aws/ into the package install dir. Run from meson's
# add_install_script machinery.
#
# Args:
#   argv0 = source dir (absolute, in the meson build tree)
#   argv1 = target dir (absolute path — the tm install dir, as passed
#           from meson.build). DESTDIR is read from the environment and
#           prepended here.

lassign $argv src_dir target_dir

if {$src_dir eq "" || $target_dir eq ""} {
	puts stderr "install_tm.tcl: usage: install_tm.tcl <src-dir> <target-dir>"
	exit 2
}

# DESTDIR handling: meson sets DESTDIR in the env when the user asks for
# a staged install (DESTDIR=/path meson install). For absolute install
# targets we concatenate — meson itself does the same for the paths it
# manages directly.
set destdir [expr {
	[info exists ::env(DESTDIR)] && $::env(DESTDIR) ne ""
	? $::env(DESTDIR)
	: ""
}]
if {$destdir ne "" && [string index $target_dir 0] eq "/"} {
	set dst $destdir$target_dir
} else {
	set dst $target_dir
}
file mkdir $dst

# The source dir won't exist if the build didn't produce any service
# modules — flag that rather than silently skipping.
if {![file isdirectory $src_dir]} {
	puts stderr "install_tm.tcl: source $src_dir does not exist"
	exit 1
}

set n 0
foreach path [glob -nocomplain [file join $src_dir *]] {
	file copy -force $path $dst/
	incr n
}
puts "Installed $n files to $dst"
