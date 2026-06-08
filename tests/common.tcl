# Shared test prelude. Source this from a test file *after* the tcltest
# bootstrap (the `package require tcltest; namespace import` block):
#
#     source [file join [file dirname [file normalize [info script]]] common.tcl]
#
# Provides: the tested package + rl_json loaded, the `json` alias, the
# `readfile` helper, and the shared live-AWS test constraints (aws_creds,
# rl_aws_account). File-specific deps (tomcrypt, aws::logs, the fixture
# stack, the s3 have_s3_bucket probe, …) stay in the individual test files.

# Shared constraints for live-AWS tests. Computed once per interpreter —
# all.tcl runs -singleproc, so every test file is sourced into the same
# interp and we don't want to re-probe credentials (a network/SSO round
# trip) once per file.
if {![info exists ::_awstcl_common]} {
	set ::_awstcl_common 1

	if {[lsearch [namespace children] ::tcltest] == -1} {
		package require tcltest
		namespace import ::tcltest::*
	}

	tcltest::loadTestedCommands
	package require aws 2
	package require rl_json 0.17
	namespace import ::rl_json::json

	# tests/ on the module path so [package require rltest] and friends resolve.
	::tcl::tm::path add [file dirname [file normalize [info script]]]
	package require rltest

	proc readfile fn {
		set h	[open $fn r]
		try {read $h} finally {close $h}
	}

	# aws_creds: real credentials are resolvable.
	tcltest::testConstraint aws_creds [try {
		aws::helpers::get_creds
		return -level 0 true
	} trap {AWS NO_CREDENTIALS} {} {
		return -level 0 false
	} on error {} {
		return -level 0 false
	}]

	# rl_aws_account: creds resolve *and* belong to Ruby Lane's account.
	# Gates tests that assert account-specific resource state. The
	# list_account_aliases IAM call is read-only and never charges.
	tcltest::testConstraint rl_aws_account [expr {
		[tcltest::testConstraint aws_creds] &&
		[try {
			expr {"rubylane" in [json get [aws iam list_account_aliases] AccountAliases]}
		} on error {} {
			return -level 0 false
		}]
	}]
}

# vim: ft=tcl foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
