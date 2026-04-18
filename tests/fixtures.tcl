# Shared helper for the aws-tcl test fixture stack.
#
# Sourced by:
#   - tests/pagination.test (for the aws_tcl_fixtures test constraint)
#   - tests/fixtures/seed_objects.tcl
#   - tests/fixtures/empty_bucket.tcl
#
# Exposes:
#   [fixture_stack_name]          - resolved stack name (env AWS_TCL_TEST_STACK or "aws-tcl-test")
#   [fixture_stack_region]        - resolved region (env AWS_REGION or "us-east-1")
#   [fixture_stack_output <key>]  - read a stack output value, cached per-process
#   [fixture_stack_ready]         - true iff stack exists and is in a complete state
#
# On stack missing or not-complete, fixture_stack_output errors. Use
# fixture_stack_ready to gate before calling.

package require aws 2
package require rl_json
if {[namespace which json] eq ""} {
	interp alias {} json {} ::rl_json::json
}

namespace eval ::fixture {
	variable _outputs_cache	{}	;# jsonstr: map of OutputKey -> OutputValue; {} = not yet loaded
	variable _status_cache

	proc stack_name {} {
		if {[info exists ::env(AWS_TCL_TEST_STACK)] && $::env(AWS_TCL_TEST_STACK) ne ""} {
			return $::env(AWS_TCL_TEST_STACK)
		}
		return aws-tcl-test
	}

	proc stack_region {} {
		if {[info exists ::env(AWS_REGION)] && $::env(AWS_REGION) ne ""} {
			return $::env(AWS_REGION)
		}
		return us-east-1
	}

	proc _load {} {
		variable _outputs_cache
		variable _status_cache
		if {$_outputs_cache ne ""} return
		set resp	[aws cloudformation describe_stacks -region [stack_region] -stack_name [stack_name]]
		set stack	[json extract $resp Stacks 0]
		set _status_cache	[json get $stack StackStatus]
		set outs	{{}}
		if {[json exists $stack Outputs]} {
			json foreach o [json extract $stack Outputs] {
				json set outs [json get $o OutputKey] [json extract $o OutputValue]
			}
		}
		set _outputs_cache	$outs
	}

	proc status {} {
		variable _status_cache
		try {_load} on error {} {return {}}
		set _status_cache
	}

	proc ready {} {
		set s	[status]
		expr {$s in {CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE}}
	}

	proc output key {
		variable _outputs_cache
		_load
		if {![json exists $_outputs_cache $key]} {
			error "Fixture stack [stack_name] has no output named \"$key\" (have: [json keys $_outputs_cache])"
		}
		json get $_outputs_cache $key
	}
}

# Flat wrapper names for convenience in caller scripts
interp alias {} fixture_stack_name   {} ::fixture::stack_name
interp alias {} fixture_stack_region {} ::fixture::stack_region
interp alias {} fixture_stack_output {} ::fixture::output
interp alias {} fixture_stack_ready  {} ::fixture::ready
interp alias {} fixture_stack_status {} ::fixture::status
