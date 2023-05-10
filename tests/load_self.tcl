set tmpath	[file normalize [file join [file dirname [info script]] ../tm]]
package ifneeded aws $ver "[list source [file join $tmpath aws-$ver.tm]]; [list package provide aws $ver]"
#package ifneeded aws::endpoints $ver "[list source [file join $tmpath aws/endpoints-$ver.tm]]; [list package provide aws::endpoints-$ver]"

foreach tm [glob -types f -tails -directory [file join $tmpath aws] *-$ver.tm] {
	set service	[lindex [split $tm -] 0]
	package ifneeded aws::$service $ver "[list source [file join $tmpath aws $tm]]; [list package provide aws::$service $ver]"
}
