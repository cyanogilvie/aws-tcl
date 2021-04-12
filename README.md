AWS-TCL
=======

Tcl related resources for AWS:
- Tcl modules implementing a subset of the AWS REST API (s3 for now, but
  includes the core API functionality for v2 and v4 request signatures).
- A base container providing a Tcl runtime for AWS Lambda.

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

AWS-Tcl-Lambda
--------------

AWS Lambda now supports using a container as the function code.  This repo
provides a base image that supplies a Tcl runtime that is compatible with
this:

myfunc.tcl:
~~~tcl
proc handler {event context} {
    puts [json pretty $event]
    return "hello, world"
}
~~~

Dockerfile:
~~~dockerfile
FROM cyanogilvie/aws-tcl-lambda
ENV LAMBDA_TASK_ROOT=/foo
WORKDIR /foo
COPY myfunc.tcl /foo
CMD ["myfunc.handler"]
~~~


License
-------
Licensed under the same terms as the Tcl core.
