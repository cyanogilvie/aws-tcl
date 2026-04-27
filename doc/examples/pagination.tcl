package require aws
package require rl_json
namespace import ::rl_json::json

# Iterate every object in a bucket — even across paginator boundaries.
# The CLI equivalent is `aws s3api list-objects-v2 --bucket assets`
# plus a NextContinuationToken loop.
aws foreach obj \
    s3 list_objects_v2 \
        -bucket assets \
        -prefix images/ \
{
    puts "[json get $obj Key] ([json get $obj Size] bytes)"
}

# Same pattern with aws lmap: produce a Tcl list by transforming each
# item. lmap runs the body once per item and collects return values.
set keys [aws lmap obj  s3 list_objects_v2 -bucket assets {
    json get $obj Key
}]

# A non-S3 example: list every CloudWatch log group across pages.
aws foreach group   logs describe_log_groups {
    puts [json get $group logGroupName]
}

# If you want per-page metadata that some services return outside of each item
aws foreach item \
        -page       page \
        -itemtype   type \
    s3 list_objects_v2 \
        -bucket     assets \
        -delimiter  / \
{
    if {[info exists page]} {
        puts "Page keycount: [json get $page KeyCount]"
        unset page  ;# Will only be set again when the next page arrives
    }

    # Some paginated services return multiple types, like s3 given -delimiter
    switch -- $type {
        CommonPrefix {
            puts "Folder: [json get $item Prefix]"
        }
        Object {
            puts "[json get $item Key] ([json get $item Size] bytes)"
        }
    }
}

# If you want to iterate over the raw items yourself, once per page:
aws foreach item \
       -page        page \
       -itemtype    type \
    s3 list_objects_v2 \
        -bucket     assets \
        -delimiter  / \
{
    json foreach object [json extract $page Contents] {
        puts "key: [json get $object Key]"
    }

    # Signal to the iteration orchestrator that we're done with the items in this page
    throw {AWS FOREACH NEXT_PAGE} {}
}
