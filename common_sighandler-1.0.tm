package require tclsignal

namespace eval ::common_sighandler {
	# Redefine this proc in the app to have custom shutdown actions
	proc clean_shutdown {} {
		exit 0
	}

	proc got_signal sig {
		if {$sig in {SIGTERM SIGINT}} {
			clean_shutdown
		}
	}

	foreach sig {
		SIGINT
		SIGTERM
	} {
		signal add $sig [list [namespace current]::got_signal $sig]
	}
}

