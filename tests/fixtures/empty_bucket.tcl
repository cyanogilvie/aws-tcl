#!/usr/bin/env tclsh9.0
# empty_bucket.tcl - list and delete every object in the fixture bucket so the
# stack can be deleted cleanly. CloudFormation won't delete a non-empty bucket.
#
# Run: `make empty-fixtures-bucket` (or tclsh9.0 tests/fixtures/empty_bucket.tcl)

set here	[file dirname [file normalize [info script]]]
tcl::tm::path add [file join $here .. .. tm]
source [file join $here .. fixtures.tcl]

set bucket	[fixture_stack_output BucketName]
set region	[fixture_stack_region]
puts stderr "emptying bucket: $bucket  (region $region)"

proc flush_batch {region bucket batchvar} {
	upvar 1 $batchvar batch
	if {[llength $batch] == 0} return
	set body	[json template {{"Objects":[], "Quiet":true}}]
	foreach key $batch {
		json set body Objects end+1 [json template {{"Key":"~S:k"}} [list k $key]]
	}
	aws s3 delete_objects -region $region -bucket $bucket -delete $body
	puts stderr "  deleted [llength $batch] objects"
	set batch	{}
}

set batch	{}
aws foreach obj -type Object s3 list_objects_V2 -region $region -bucket $bucket -page_size 1000 {
	lappend batch [json get $obj Key]
	if {[llength $batch] >= 1000} {
		flush_batch $region $bucket batch
	}
}
flush_batch $region $bucket batch

puts stderr "done"
