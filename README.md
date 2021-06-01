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
whereas the generated Tcl bindings are a little over half a MB.  In situations
where a small image is a requirement (such as this one), including the AWS CLI is
simply not an option.

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

Build Flags
-----------

Since Nov 2020 AVX2 support is available to Lambda functions in all regions
other than China, so all the sources for this image are built with that
support.  If you need other hardware support, override the CFLAGS arg.

Included Packages
-----------------

| Package | Version | Source |
| --- | --- | --- |
| Tcl | 8.7a4 | https://core.tcl-lang.org/tcl/tarball/99b8ad35a258cade/tcl.tar.gz |
| Thread | 2.9a1 | https://core.tcl-lang.org/thread/tarball/2a83440579/thread.tar.gz |
| tdbc | 1.1.1 | https://github.com/cyanogilvie/tdbc/archive/1f8b684.tar.gz |
| pgwire | 3.0.0b2 | https://github.com/cyanogilvie/pgwire/archive/v3.0.0b2.tar.gz |
| tdom | 0.9.3 | https://github.com/RubyLane/tdom/archive/cyan-0.9.3.1.tar.gz |
| tls | 1.7.22 | https://core.tcl-lang.org/tcltls/tarball/tls-1-7-22/tcltls.tar.gz |
| parse_args | 0.3.2 | https://github.com/RubyLane/parse_args/archive/v0.3.2.tar.gz |
| rl_json | 0.11.0 | https://github.com/RubyLane/rl_json/archive/c5a8033.tar.gz |
| hash | 0.3 | https://github.com/cyanogilvie/hash/archive/79c2066.tar.gz |
| unix_sockets | 0.2 | https://github.com/cyanogilvie/unix_sockets/archive/761daa5.tar.gz |
| tcllib | 1.20 | https://core.tcl-lang.org/tcllib/uv/tcllib-1.20.tar.gz |
| gc_class | 1.0 | https://github.com/RubyLane/gc_class/archive/f295f65.tar.gz |
| rl_http | 1.9 | https://github.com/RubyLane/rl_http/archive/1.9.tar.gz |
| sqlite3 | 3.35.4 | https://sqlite.org/2021/sqlite-autoconf-3350400.tar.gz |
| tcc4tcl | 0.30.1 | https://github.com/cyanogilvie/tcc4tcl/archive/b8171e0.tar.gz |
| cflib | 1.14.1 | https://github.com/cyanogilvie/cflib/archive/da5865b.tar.gz |
| sop | 1.7.0 | https://github.com/cyanogilvie/sop/archive/cb74e34.tar.gz |
| netdgram | 0.9.11 | https://github.com/cyanogilvie/netdgram/archive/v0.9.11.tar.gz |
| evlog | 0.3.1 | https://github.com/cyanogilvie/evlog/archive/c6c2529.tar.gz |
| dsl | 0.4 | https://github.com/cyanogilvie/dsl/archive/f24a59e.tar.gz |
| logging | 0.3 | https://github.com/cyanogilvie/logging/archive/e709389.tar.gz |
| sockopt | 0.2 | https://github.com/cyanogilvie/sockopt/archive/c574d92.tar.gz |
| crypto | 0.6 | https://github.com/cyanogilvie/crypto/archive/7a04540.tar.gz |
| m2 | 0.43.13 | https://github.com/cyanogilvie/m2/archive/v0.43.13.tar.gz |
| urlencode | 1.0 | https://github.com/cyanogilvie/aws-tcl |
| hmac | 0.1 | https://github.com/cyanogilvie/aws-tcl |
| tclreadline | 2.3.8.1 | https://github.com/cyanogilvie/tclreadline/archive/v2.3.8.1.tar.gz |
| Expect | 5.45.4 | https://core.tcl-lang.org/expect/tarball/f8e8464f14/expect.tar.gz |
| tclsignal | 1.4.4.1 | https://github.com/cyanogilvie/tclsignal/archive/v1.4.4.1.tar.gz |
| type | 0.2 | https://github.com/cyanogilvie/type/archive/v0.2.tar.gz |
| inotify | 2.2 | https://github.com/cyanogilvie/inotify/archive/298f608.tar.gz |
| Pixel | 3.5 | https://github.com/cyanogilvie/pixel/archive/2c70755.tar.gz |
| Pixel_jpeg | 1.4 | https://github.com/cyanogilvie/pixel/archive/2c70755.tar.gz |
| Pixel_png | 2.6 | https://github.com/cyanogilvie/pixel/archive/2c70755.tar.gz |
| Pixel_svg_cairo | 0.3 | https://github.com/cyanogilvie/pixel/archive/2c70755.tar.gz |
| Pixel_webp | 1.0 | https://github.com/cyanogilvie/pixel/archive/2c70755.tar.gz |
| Pixel_imlib2 | 1.2.0 | https://github.com/cyanogilvie/pixel/archive/2c70755.tar.gz |
| chantricks | 1.0.3 | https://github.com/cyanogilvie/chantricks/archive/v1.0.3.tar.gz |
| openapi | 0.4.11 | https://github.com/cyanogilvie/tcl-openapi/archive/v0.4.11.tar.gz |
| docker | 0.9.0 | https://github.com/cyanogilvie/tcl-docker-client/archive/v0.9.0.tar.gz |
| aws | 1.2 | https://github.com/cyanogilvie/aws-tcl |
| aws1::s3 | 1.0 | https://github.com/cyanogilvie/aws-tcl |
| aws1::cognito_identity | 1.0 | https://github.com/cyanogilvie/aws-tcl |
| aws1::secretsmanager | 0.1 | https://github.com/cyanogilvie/aws-tcl |
| aws1::ecr | 1.0 | https://github.com/cyanogilvie/aws-tcl |
| aws | 2.0a2 | https://github.com/cyanogilvie/aws-tcl |
| parsetcl | 0.1 | https://github.com/cyanogilvie/parsetcl/archive/030a1439b76747ec7a016c5bd0ae78c93fc9bb7b.tar.gz |
| tty | 0.4 | https://github.com/cyanogilvie/tcl-tty/archive/v0.4.tar.gz |

aws 2.0a1 supports all the services of the aws cli except for ec2 currently.

For Pixel_svg_cairo to be usable it needs librsvg, which isn't added by default because it more than doubles the image size.  To use it, derive a new image like so:

~~~dockerfile
FROM cyanogilvie/alpine-tcl-stripped
RUN apk add --no-cache librsvg
~~~

Similarly, Pixel_imlib2 requires imlib2:

~~~dockerfile
FROM cyanogilvie/alpine-tcl-stripped
RUN apk add --no-cache imlib2
~~~

License
-------
Licensed under the same terms as the Tcl core.
