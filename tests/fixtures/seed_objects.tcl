#!/usr/bin/env tclsh9.0
# seed_objects.tcl - put a curated set of test objects in the fixture bucket.
#
# Object names are chosen to exercise sigv4 signing edge cases (spaces, UTF-8,
# reserved URL characters, brackets, parens, tilde) and to give a useful mix of
# Object and CommonPrefix entries when listed with -delimiter /.
#
# Run: `make seed-fixtures` (or tclsh9.0 tests/fixtures/seed_objects.tcl)

set here	[file dirname [file normalize [info script]]]
tcl::tm::path add [file join $here .. .. tm]
source [file join $here .. fixtures.tcl]

set bucket	[fixture_stack_output BucketName]
set region	[fixture_stack_region]
puts stderr "seeding bucket: $bucket  (region $region)"

# Keys chosen for signing/encoding coverage. Values are trivial.
set objects {
	"readme.txt"                        "baseline root-level object\n"
	"files/plain.txt"                   "baseline nested object\n"
	"files/with space.txt"              "key containing a space\n"
	"files/unicode-é-✓.txt"             "UTF-8 bytes in key\n"
	"files/reserved+=&?#.txt"           "URL-reserved characters in key\n"
	"files/parens-(test).txt"           "parens in key\n"
	"files/brackets-\[test\].txt"       "square brackets in key\n"
	"files/tilde-~test.txt"             "tilde (unreserved) in key\n"
	"files/deep/nested/path.txt"        "deeply nested key\n"
	"zone-a/file-01.txt"                "sibling prefix A, file 1\n"
	"zone-a/file-02.txt"                "sibling prefix A, file 2\n"
	"zone-b/file-03.txt"                "sibling prefix B\n"
}

foreach {key body} $objects {
	puts stderr "  put: $key"
	aws s3 put_object \
		-region $region \
		-bucket $bucket \
		-key    $key \
		-body   [encoding convertto utf-8 $body]
}
puts stderr "seeded [expr {[llength $objects] / 2}] objects"
