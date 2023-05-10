AWS-TCL
=======

An implementation of the AWS API in Tcl, with a focus on small size (around 1MB).

API
---

The API attempts to authenticate with with the AWS REST API using any
contextual credentials it can find (instance roles on EC2, execution roles on
Lambda, ECS / Fargate, etc) in a similar fashion to the AWS CLI.  So if your
code is running on the AWS platform and you want to interact with other AWS
services using the IAM instance role assigned to whatever is running the code,
you don't have to do anything.  If your code isn't running on AWS or you need
to override the default credentials, they can be supplied in the calls using the
-aws_id, -aws_key and -aws_token arguments.

The core API layer supports the ratelimiting negotiation used by the AWS API,
and will back off and limit the request rate if it receives "slow down" errors
(and transparently re-issue the failed requests).

~~~tcl
package require aws::s3
package require rl_json

namespace import rl_json::*

# Upload an image
s3 upload \
    -region         us-east-1 \
    -bucket         assets \
    -path           foo/bar.jpg \
    -content_type   image/jpeg \
    -data           $image_bytes \
    -acl            public-read

# List files matching a prefix on a bucket.  S3 returns a limited number of
# results per response, so to support very large results we use continuation
# tokens:

set continuation_token ""
while {[info exists continuation_token]} {
    set batch [s3 ls \
        -continuation_token   $continuation_token \
        -region               us-east-1 \
        -bucket               assets \
        -prefix               images/foo \
        -delimiter            /]

    set continuation_token  [json get $batch next_continuation_token]
    if {$continuation_token eq ""} {unset continuation_token}
    json foreach entry [json extract $batch results] {
        puts "matched: [json get $entry key]"
    }
}
~~~

API v2
------

The AWS API package version 2 switches to using generated code to implement
the various aws services, derived from the JSON description files that are
used by botocore (and therefore the standard AWS CLI).  This means that the
interface presented by v2 is very similar to the AWS CLI - except that 
underscores are used in place of dashes, and options are preceded by a single
dash rather than two.  So:

~~~sh
aws lambda list-functions --function-version ALL
~~~

becomes:

~~~tcl
package require aws::lambda 2
aws lambda list_functions -function_version ALL
~~~

As indicated by the version suffix, version 2 is still in alpha, and isn't
complete yet (the ec2 service uses a different protocol which still needs
to be implemented).  It's also very likely still full of bugs from the guesses
I had to make when reverse engineering the botocore JSON description.

It would be trivial to just use the AWS CLI from Tcl like so:

~~~tcl
exec aws list-functions --function-version ALL
~~~

but including the AWS CLI increases the size of an image hugely - the official
AWS CLI docker image is 300 MB, and a hacked one based on alpine linux is 150 MB,
whereas the generated Tcl bindings are a little under a MB.  In situations
where a small image is a requirement, including the AWS CLI is
simply not an option.

License
-------
Licensed under the same terms as the Tcl core.
