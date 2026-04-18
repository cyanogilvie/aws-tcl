set tmpath	[file normalize [file join [file dirname [info script]] ../tm]]
# Optional extra .tm search paths for dev setups where a dependency
# (e.g. rl_http, rl_json) isn't system-installed. Colon-separated.
if {[info exists ::env(AWSTCL_EXTRA_TM_PATH)]} {
	foreach p [split $::env(AWSTCL_EXTRA_TM_PATH) :] {
		if {$p ne ""} {tcl::tm::path add $p}
	}
}
package ifneeded aws $ver "[list source [file join $tmpath aws-$ver.tm]]; [list package provide aws $ver]"
#package ifneeded aws::endpoints $ver "[list source [file join $tmpath aws/endpoints-$ver.tm]]; [list package provide aws::endpoints-$ver]"
package ifneeded hmac 0.1 "[list source [file join $tmpath hmac-0.1.tm]]; [list package provide hmac 0.1]"

foreach tm [glob -types f -tails -directory [file join $tmpath aws] *-$ver.tm] {
	set service	[lindex [split $tm -] 0]
	package ifneeded aws::$service $ver "[list source [file join $tmpath aws $tm]]; [list package provide aws::$service $ver]"
}

