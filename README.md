# NAME

aws - AWS service bindings for Tcl, modelled on the AWS CLI

## SYNOPSIS

**package require aws** ?2.0a33?

**package require aws::**\<*service*\>

**aws** *service* *operation* ?*-option* *value* …?\
**aws** **foreach** *varlist* *service* *operation* ?*-option* *value*
…? *body*\
**aws** **lmap** *varlist* *service* *operation* ?*-option* *value* …?
*body*\
**aws** **endpoint** **-service** *service* ?**-region** *region*?\
**::aws::helpers::set_creds** **-access_key** *key* **-secret** *secret*
?**-token** *token*?

## DESCRIPTION

The **aws** package is an AWS SDK generated from the botocore service
definitions that back the AWS CLI. Operation names, option names, and
semantics are deliberately close to the CLI so that knowledge of
`aws <service> <operation>` carries over directly; this manpage
documents only where a Tcl script must be written differently from the
CLI, and refers the reader to the AWS CLI reference for per-operation
documentation at <https://docs.aws.amazon.com/cli/latest/reference/>.

Configuration (profiles, credentials, region, retries, endpoint
overrides, TLS trust) follows the AWS CLI’s resolution rules — see
**CONFIGURATION** below for the full list of env vars and profile keys
honored, and the places where behaviour differs.

## TRANSLATING CLI INVOCATIONS

### Loading services

Each AWS service lives in its own sub-package. The top-level `aws`
ensemble auto-loads them on first use, so for most code a single

``` tcl
package require aws
aws s3 list_buckets
```

is sufficient.

### Option format

The CLI uses `--double-dashed` options in `kebab-case`. The Tcl SDK uses
single-dashed options in `snake_case`, matching Tcl convention:

| AWS CLI | Tcl SDK |
|----|----|
| `--function-name foo` | `-function_name foo` |
| `--max-items 10` | `-max_items 10` |
| `--cli-input-json file://req.json` | not supported — pass arguments directly |

Operation names convert the same way: `list-functions` →
`list_functions`, `get-caller-identity` → `get_caller_identity`.

### Return values

Every operation returns a JSON document (a Tcl string containing valid
JSON). The **rl_json** package handles navigation and extraction — the
conventional alias at the top of a script is:

``` tcl
package require rl_json
interp alias {} json {} ::rl_json::json
```

which makes `json get`, `json extract`, `json foreach`, etc. resolve
without the namespace prefix. Inside `aws::*` service namespaces the
alias is unnecessary — `namespace path` already imports **rl_json**.

### Array / list inputs

Where the CLI takes a space-separated list:

``` sh
aws ec2 describe-instances --instance-ids i-aaa i-bbb
```

the Tcl SDK takes a Tcl list:

``` tcl
aws ec2 describe_instances -instance_ids {i-aaa i-bbb}
```

### Structure / map inputs (json-family protocols)

Services using the json, rest-json, json_1.0, or rest-xml protocols
(dynamodb, lambda, ecs, s3, cloudfront, route53, and many others) accept
nested values (structures, maps, and lists, including top-level lists)
as JSON fragments, not as Tcl dicts or lists. Use the `~J:`, `~S:`,
`~N:`, `~B:` substitution forms from **rl_json**’s `json template`:

``` tcl
set tags [json template {["~S:a", "~S:b"]}]
set item [json template {
    {
        "pk":     {"S":  "~S:pk"},
        "sk":     {"S":  "~S:sk"},
        "count":  {"N":  "~S:count"},
        "tags":   {"SS": "~J:tags"}
    }
}]
aws dynamodb put_item \
    -table_name Users \
    -item       $item

aws cloudfront create_invalidation \
    -distribution_id    E2R4RHYW3FOCFL \
    -invalidation_batch [json template {
        {
            "Paths":           {"Quantity": 1, "Items": ["/index.html"]},
            "CallerReference": "~S:ref"
        }
    }]
```

Keys inside the fragment are the botocore member names (the same keys
the CLI’s JSON input uses); wire-level renames, base64 encoding of
nested blobs, and timestamp formatting are applied by the SDK. For
rest-xml services the SDK converts the fragment to the XML request body.

This is a deliberate design choice: nested JSON is frequently
constructed by composition, and round-tripping through Tcl dicts loses
type information (boolean vs string, number vs string). The query and
ec2 protocols (iam, sts, cloudformation, ec2, …) take Tcl-native nested
values instead: lists as Tcl lists, structures as dicts keyed by member
name (see the `describe_instances` example under **COMMON
TRANSLATIONS**).

### smithy-rpc-v2-cbor services

A few newer services only offer the Smithy RPC v2 CBOR protocol
(currently `cloudwatchomni`, `eventbridgev2` and
`partnercentral_revenue_measurement`). They look exactly like the
json-family services from Tcl: nested inputs are JSON fragments, and the
result is the same rl_json value a json service would return (blobs
base64-encoded, timestamps as epoch seconds, NaN / Infinity as the
strings `"NaN"`, `"Infinity"`, `"-Infinity"`). Errors carry the same
`{AWS <__type> <request-id> ...}` error code.

On the wire the request and response bodies are CBOR, converted by a
small C module compiled at runtime by **jitc** against **rl_json** and
**cbor** the first time one of these services is called, so they need
Tcl 9 with the **jitc** (\>= 0.8) and **cbor** (\>= 1.2) packages
installed. Without them the call fails with `{AWS UNSUPPORTED cbor}`.
Services that offer CBOR alongside a JSON protocol (cloudwatch and
others) use the JSON protocol, and don’t need either package.

### Operations that return blobs

Binary outputs are byte-string Tcl values. Where the whole response body
is the blob (e.g. `s3 get_object`), pass `-payload varname` to receive
it; the return value then holds the metadata from the response headers:

``` tcl
set meta [aws s3 get_object -bucket assets -key logo.png -payload bytes]
```

Blobs embedded in a JSON response (e.g. the `lambda invoke` `Payload`)
are returned in the JSON. Use `binary format` / `binary scan` /
`chan write` to handle them; do not `puts` them to a text channel
without a `-translation binary` configuration.

## PAGINATION

Replace `aws ... | jq .NextToken` loops with **aws foreach** or **aws
lmap**. These iterators drive the paginator definitions shipped with
botocore (the same ones the CLI uses for `--max-items` / `--page-size`)
and hide the continuation-token plumbing:

``` tcl
aws foreach bucket s3 list_buckets {
    puts [json get $bucket Name]
}

set names [aws lmap bucket s3 list_buckets {
    json get $bucket Name
}]
```

The first argument after `foreach` / `lmap` is the loop variable name;
the body runs once per *item* across all pages. There is no
`--no-paginate` equivalent — if you want a single page, just call the
underlying operation (`aws s3 list_buckets -max_buckets 100`) and
iterate the result yourself.

Paginator metadata (what counts as a page, which key is the continuation
token, which key is the items array) comes from `paginators-1.json` in
botocore and is baked into the generated service modules at build time.

## REGION SELECTION

Resolution order matches the CLI:

1.  A per-call `-region` option
    (`aws s3 list_buckets -region eu-west-1`).
2.  `AWS_REGION` environment variable.
3.  `AWS_DEFAULT_REGION` environment variable.
4.  `region =` in the active profile (from `AWS_PROFILE` →
    `AWS_DEFAULT_PROFILE` → `default`).
5.  `us-east-1` as a last-resort fallback.

The process-level default is cached in `$::aws::default_region` at
package-load time from sources 2 – 5; set it explicitly if you need to
change it for the rest of the process without touching env vars or
writing to the config file.

## CONFIGURATION

The following environment variables and profile-file keys are honored
with AWS-CLI-compatible semantics. See the AWS CLI reference at
<https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html>
for the authoritative meaning of each — this section lists only what
aws-tcl implements, and notes the places where behaviour differs.

### Profile and file location

| Purpose               | Env var                              | Config key |
|-----------------------|--------------------------------------|------------|
| Active profile        | `AWS_PROFILE`, `AWS_DEFAULT_PROFILE` | n/a        |
| Config file path      | `AWS_CONFIG_FILE`                    | n/a        |
| Credentials file path | `AWS_SHARED_CREDENTIALS_FILE`        | n/a        |

`AWS_PROFILE` wins over `AWS_DEFAULT_PROFILE`; both fall back to
`default`. Config-file section naming matches the CLI: bare profile
names in the credentials file (`[myprofile]`), `[profile NAME]` in the
config file (except for the default profile, which is bare).

### Credentials

Credential providers are tried in this order; the first that yields a
credential wins:

1.  A static override set by **::aws::helpers::set_creds**.
2.  `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (+ optional
    `AWS_SESSION_TOKEN`).
3.  `AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE` — calls
    `sts:AssumeRoleWithWebIdentity`. Used by EKS IRSA and Pod Identity.
4.  The active profile. Within the profile, these providers are tried in
    order:
    - `credential_process` — runs the configured command, parses its
      JSON stdout (with `Version`, `AccessKeyId`, `SecretAccessKey`,
      optional `SessionToken`, optional `Expiration`).
    - `role_arn` + `web_identity_token_file` —
      `sts:AssumeRoleWithWebIdentity`.
    - `role_arn` + `source_profile` (or `credential_source` =
      `Environment` / `Ec2InstanceMetadata` / `EcsContainer`) —
      `sts:AssumeRole` chain; `external_id`, `role_session_name`,
      `duration_seconds` all honored.
    - `sso_session =` (modern sso-session form) or `sso_start_url`
      (legacy form): reads the token cache that `aws sso login`
      maintains at `~/.aws/sso/cache/<sha1>.json` and calls
      `sso:GetRoleCredentials`. If the access token is expired and a
      `refreshToken` is present, a `sso-oidc:CreateToken` refresh is
      attempted and written back to the cache.
    - Static `aws_access_key_id` / `aws_secret_access_key` /
      `aws_session_token`.
5.  Container credentials via `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`
    (ECS task role) or `AWS_CONTAINER_CREDENTIALS_FULL_URI` +
    `AWS_CONTAINER_AUTHORIZATION_TOKEN` / `..._TOKEN_FILE` (EKS Pod
    Identity Agent).
6.  EC2 instance metadata (IMDSv2 preferred, v1 as fallback unless
    `AWS_EC2_METADATA_V1_DISABLED=true`). `AWS_EC2_METADATA_DISABLED`,
    `AWS_METADATA_SERVICE_TIMEOUT`, `AWS_METADATA_SERVICE_NUM_ATTEMPTS`,
    and `AWS_EC2_METADATA_SERVICE_ENDPOINT` are honored.

### SSO / IAM Identity Center

Supported via the CLI’s token cache — aws-tcl reads
`~/.aws/sso/cache/<sha1(session_name or start_url)>.json`, exchanges the
access token for short-lived role credentials via
`sso:GetRoleCredentials`, and refreshes the access token via
`sso-oidc:CreateToken` when a refresh token is present.

**aws-tcl does not implement the interactive device-code login flow.**
Run `aws sso login` (optionally with `--profile NAME`) from the AWS CLI
to establish a session; aws-tcl picks up the resulting token the next
time a request is signed. If the session has expired beyond what refresh
can recover, a clear `{AWS SSO_TOKEN_EXPIRED}` error is raised advising
you to re-run `aws sso login`.

### Endpoint overrides

`AWS_ENDPOINT_URL_<SERVICE>` (per-service) and `AWS_ENDPOINT_URL`
(global), plus `endpoint_url =` in the active profile. Useful for
LocalStack, VPC endpoints, and private-link testing. Only the scheme /
host / port of the URL are used; request paths built from the
operation’s `httpRequestUri` are preserved.

Service name matching for `AWS_ENDPOINT_URL_<SERVICE>` uses uppercase
with hyphens converted to underscores
(e.g. `AWS_ENDPOINT_URL_TRANSCRIBE_STREAMING`).

### FIPS / dualstack / STS regional

| Setting        | Env var                      | Config key               |
|----------------|------------------------------|--------------------------|
| FIPS endpoints | `AWS_USE_FIPS_ENDPOINT`      | `use_fips_endpoint`      |
| Dualstack      | `AWS_USE_DUALSTACK_ENDPOINT` | `use_dualstack_endpoint` |
| STS regional   | `AWS_STS_REGIONAL_ENDPOINTS` | `sts_regional_endpoints` |

Endpoint-rule builtins feed these through to the per-service endpoint
resolution.

### TLS trust

`AWS_CA_BUNDLE` or profile `ca_bundle =` selects a PEM bundle that
**replaces** the system trust store for service requests — matching CLI
semantics, not the additive behaviour of some other SDKs.

## RETRIES AND RATE LIMITING

Matching the AWS SDK v2 / v3 conventions:

| Setting     | Env var            | Config key     | Default    |
|-------------|--------------------|----------------|------------|
| Retry mode  | `AWS_RETRY_MODE`   | `retry_mode`   | `standard` |
| Attempt cap | `AWS_MAX_ATTEMPTS` | `max_attempts` | `3`        |

All modes retry with full-jitter exponential backoff (honouring
`Retry-After`). `standard` (and `adaptive`, currently treated the same)
also paces sends per service and region: a throttling response halves
the allowed send rate, which recovers after 10 s without throttles.
`legacy` skips the pacing.

The retry classifier recognises:

- AWS throttling codes (`Throttling`, `SlowDown`,
  `ProvisionedThroughputExceededException`, etc.)
- Transient codes (`InternalError`, `ServiceUnavailable`,
  `RequestTimeout`, …)
- HTTP statuses `408`, `425`, `429`, `500`, `502`, `503`, `504`, `509`

Rate-limit state is kept in process-scoped `tsv` arrays, so throttling
observed on one thread influences subsequent sends from other threads
that share the **rl_http** keepalive pool.

Idempotency tokens on operations that declare one (ubiquitous on
`Create*` ops that accept a `ClientToken`) are auto-populated with a
UUIDv4 if the caller doesn’t supply one, so a retry reaches the same
logical request.

## TIMEOUTS

Three HTTP budgets, mirroring the AWS SDK v2 shape. Because the
governing env var names differ slightly from the CLI’s (which has no
direct equivalents), the aws-tcl prefix `AWSTCL_` is used to avoid
colonising the `AWS_` namespace:

| Setting         | Env var                  | Default |
|-----------------|--------------------------|---------|
| Request budget  | `AWSTCL_REQUEST_TIMEOUT` | 60 s    |
| Connect budget  | `AWSTCL_CONNECT_TIMEOUT` | 5 s     |
| Read gap budget | `AWSTCL_READ_TIMEOUT`    | 30 s    |

Request budget is a hard ceiling on overall wall-clock time per attempt
(not per retry cycle). Connect budget caps the DNS + TCP + TLS
handshake. Read budget caps the inter-chunk silence during a body stream
(so a 30-second read gap fails, even if total bytes are still flowing
steadily).

The connection-pool parking age, `AWSTCL_MAX_KEEPALIVE_AGE` (default 60
s), matches the Java SDK v2 convention and balances keepalive efficiency
against S3/DynamoDB partition-scale opacity.

## ERRORS

AWS service errors are raised as Tcl exceptions with an `errorCode` of
the form:

    AWS <Code> <RequestId> <Resource> <Details>

where:

- **Code** is the service-defined error code (e.g. `NoSuchBucket`,
  `ValidationException`, `InvalidInstanceID.Malformed`). Some json
  protocol services (DynamoDB among them) report a namespace-qualified
  code such as
  `com.amazonaws.dynamodb.v20120810#ResourceNotFoundException`.
- **RequestId** is the AWS request id.
- **Resource** is the `Resource` element of an XML error response (S3),
  otherwise empty.
- **Details** (XML protocols) is a key/value list of every field of the
  error element (`BucketName`, `Key`, `HostId`, …).

The result is the AWS error message (prefixed with `AWS:` for XML
protocols). An error response with no parseable body raises
`AWS <httpStatus>`, e.g. `AWS 404` from `s3 head_object`.

Typical pattern:

``` tcl
try {
    aws s3 get_object -bucket assets -key $key -payload bytes
} trap {AWS NoSuchKey} {} {
    # object doesn't exist
} trap AWS {msg opts} {
    # any other AWS-side failure
    log warn "s3: $msg ([lindex [dict get $opts -errorcode] 1])"
}
```

Throttling and transient errors have already been retried (see **RETRIES
AND RATE LIMITING**) by the time they reach the caller.

Transport-level failures (DNS, TCP reset, TLS) that persist through the
retries propagate with the underlying socket / **rl_http** errorCode,
which does not start with `AWS`.

**Credential-resolution errors** have their own taxonomy:

- `AWS NO_CREDENTIALS` — no provider yielded a credential.
- `AWS SSO_NO_TOKEN` / `AWS SSO_TOKEN_EXPIRED` / `AWS SSO_TOKEN_INVALID`
  / `AWS SSO_REFRESH_FAILED` — SSO failures.
- `AWS CREDENTIAL_PROCESS` — `credential_process` invocation failure.
- `AWS PROFILE_INVALID` / `AWS PROFILE_CYCLE` — malformed profile
  config.
- `AWS UNSUPPORTED` — the profile asks for something we don’t implement
  (currently: `mfa_serial`).

## WHAT’S NOT IMPLEMENTED

Things a CLI user might reach for that aren’t in this SDK:

- **`--query` / JMESPath filtering.** Use **rl_json**’s `json get`,
  `json extract`, `json foreach` — JMESPath’s niche overlaps
  substantially with rl_json’s navigation.
- **`--output table` / `--output text` / `--output yaml`.** Every
  operation returns JSON. Format to taste from there.
- **`--cli-input-json file://…`.** The Tcl SDK accepts all input as
  typed option arguments; serialise JSON yourself if that’s your input
  format (`aws s3 put_object -body [readfile doc.json]`).
- **Interactive SSO login (device code flow).** Run `aws sso login` from
  the CLI.
- **MFA-gated AssumeRole.** `mfa_serial` in a profile raises
  `{AWS UNSUPPORTED}` — there is no hook for the SDK to prompt. Obtain a
  session token with `aws sts get-session-token` and export through env
  vars instead.
- **Shell completion helpers.**

## COMMON TRANSLATIONS

``` tcl
package require aws
package require rl_json
namespace import ::rl_json::json

# aws sts get-caller-identity
set ident [aws sts get_caller_identity]
puts "account: [json get $ident Account]"

# aws s3api head-object --bucket assets --key foo/bar.jpg
set meta [aws s3 head_object -bucket assets -key foo/bar.jpg]
puts "size: [json get $meta ContentLength]"

# aws ec2 describe-instances \
#     --instance-ids    i-aaa i-bbb \
#     --filters         "Name=tag:Env,Values=prod"
set instances [aws ec2 describe_instances \
    -instance_ids   {i-aaa i-bbb} \
    -filters        [list [dict create Name tag:Env     Values prod]]]

# aws dynamodb put-item \
#     --table-name  Users \
#     --item        '{"pk":{"S":"user#42"},"count":{"N":"7"}}'
set pk      user#42
set count   7
set item [json template {
    {
        "pk":    { "S": "~S:pk"    },
        "count": { "N": "~S:count" }
    }
}]
aws dynamodb put_item -table_name Users -item $item

# aws lambda invoke --function-name worker --payload '{"op":"reindex"}' out.json
set resp [aws lambda invoke \
    -function_name  worker \
    -payload        [json template {{"op":"~S:op"}} {op reindex}]]
set fh [open out.json wb]
try {
    puts -nonewline $fh [json get $resp Payload]
} finally {
    close $fh
}
```

## PAGINATION EXAMPLE

``` tcl
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
```

## ERROR HANDLING EXAMPLE

``` tcl
package require aws
package require rl_json
namespace import ::rl_json::json

# Service error codes are part of the Tcl errorCode, so you can pattern
# match on them with `try ... trap`. This is the preferred shape —
# catching by string match on the error message is brittle across
# service wording changes.
proc get_user user_id {
    try {
        aws dynamodb get_item \
            -table_name Users \
            -key        [json template {{"pk":{"S":"~S:user_id"}}}]
    } trap AWS {msg opts} {
        # DynamoDB reports namespace-qualified codes
        # (com.amazonaws.dynamodb.v20120810#ResourceNotFoundException),
        # which trap's prefix matching can't glob, so match on the
        # unqualified tail of the code here.
        set code [lindex [dict get $opts -errorcode] 1]
        switch -- [lindex [split $code #] end] {
            ResourceNotFoundException {
                # Table doesn't exist. Different from "item not found" —
                # an empty Item in the response means the row is absent.
                throw {APP TABLE_MISSING} "Users table is not provisioned"
            }
            ProvisionedThroughputExceededException {
                throw {APP OVERLOADED} "DynamoDB throttling — try again shortly"
            }
        }
        return -options $opts $msg
    }
}

# S3 errors carry the request id, resource and every field of the XML
# error element in the errorCode: {AWS Code RequestId Resource Details}
try {
    aws s3 put_object -bucket private -key secrets.txt -body $data
} trap {AWS AccessDenied} {msg opts} {
    lassign [dict get $opts -errorcode] - code requestid resource details
    log error "s3 upload to $resource denied (request $requestid): $msg"
} trap AWS {msg opts} {
    # Tcl's trap pattern matching is prefix-based, so {AWS} matches any
    # AWS-side error.
    log error "s3 upload failed: [dict get $opts -errorcode] $msg"
}

# Credential-resolution errors are distinct from service errors.
try {
    aws sts get_caller_identity
} trap {AWS SSO_TOKEN_EXPIRED} msg {
    puts stderr "Run 'aws sso login' to refresh your session."
    exit 1
} trap {AWS NO_CREDENTIALS} {} {
    puts stderr "No AWS credentials found in env, profile, or metadata."
    exit 1
}
```

## ENVIRONMENT

AWS-CLI-compatible (see **CONFIGURATION**):

`AWS_PROFILE`, `AWS_DEFAULT_PROFILE`, `AWS_CONFIG_FILE`,
`AWS_SHARED_CREDENTIALS_FILE`, `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`,
`AWS_DEFAULT_REGION`, `AWS_ENDPOINT_URL`, `AWS_ENDPOINT_URL_<SERVICE>`,
`AWS_USE_FIPS_ENDPOINT`, `AWS_USE_DUALSTACK_ENDPOINT`,
`AWS_STS_REGIONAL_ENDPOINTS`, `AWS_RETRY_MODE`, `AWS_MAX_ATTEMPTS`,
`AWS_CA_BUNDLE`, `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`,
`AWS_ROLE_SESSION_NAME`, `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`,
`AWS_CONTAINER_CREDENTIALS_FULL_URI`,
`AWS_CONTAINER_AUTHORIZATION_TOKEN`,
`AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`, `AWS_EC2_METADATA_DISABLED`,
`AWS_EC2_METADATA_V1_DISABLED`, `AWS_EC2_METADATA_SERVICE_ENDPOINT`,
`AWS_METADATA_SERVICE_TIMEOUT`, `AWS_METADATA_SERVICE_NUM_ATTEMPTS`.

aws-tcl-specific (not defined by the CLI):

`AWSTCL_REQUEST_TIMEOUT`, `AWSTCL_CONNECT_TIMEOUT`,
`AWSTCL_READ_TIMEOUT`, `AWSTCL_MAX_KEEPALIVE_AGE`,
`AWSTCL_EXTRA_TM_PATH`.

## SEE ALSO

- AWS CLI reference: <https://docs.aws.amazon.com/cli/latest/reference/>
- AWS CLI configuration guide:
  <https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html>
- **rl_json**(n) — the JSON library used for inputs and outputs
- **reuri**(n) — the URI parser used internally

## BUGS

Report issues at <https://github.com/cyanogilvie/aws-tcl>.
