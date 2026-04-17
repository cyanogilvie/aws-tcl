# Endpoint rule engine

AWS services carry an "endpoint rule set" — a declarative program that
takes input parameters (Region, UseFIPS, bucket, etc.) and outputs an
endpoint URL plus signing metadata. We compile these rule sets to Tcl
proc bodies at build time.

## Input: endpoint-rule-set-1.json

Each service has one. Structure:

```json
{
    "version": "1.0",
    "parameters": {
        "Region":         {"builtIn":"AWS::Region","required":false,"type":"string"},
        "UseFIPS":        {"builtIn":"AWS::UseFIPS","required":true,"default":false,"type":"boolean"},
        "Endpoint":       {"builtIn":"SDK::Endpoint","required":false,"type":"string"},
        "ResourceArnList": {"required":false,"type":"stringArray"}
    },
    "rules": [
        { "conditions":[...], "rules":[...], "type":"tree" },
        { "conditions":[], "endpoint":{"url":"..."}, "type":"endpoint" },
        { "conditions":[...], "error":"...", "type":"error" }
    ]
}
```

Parameter `type` is lowercase in newer definitions (`string`,
`boolean`, `stringArray`) — the compiler accepts any case via
`string tolower`.

## Rule kinds

- `tree`: evaluate `conditions`; if all true, recurse into `rules`.
- `endpoint`: evaluate `conditions`; if true, return the endpoint.
- `error`: evaluate `conditions`; if true, throw the error message.

## Condition fn set

Supported condition functions (see `compile_arg` in build.tcl):

| fn | Notes |
|---|---|
| `booleanEquals` | `aws_b($lhs) == aws_b($rhs)`; true-literal shortcut |
| `isSet` | on a ref: `[info exists p(X)]`; on a getAttr: `[json exists ...]`; on any other fn: truthy catch |
| `stringEquals` | string equality with template-expansion support |
| `not` | negation |
| `getAttr` | JSON-path navigation with array-index support |
| `aws.partition` | region → partition info; always returns a partition (falls back to `aws`) |
| `aws.parseArn` | ARN → struct; returns null for malformed |
| `aws.isVirtualHostableS3Bucket` | bucket name DNS-compatible check |
| `isValidHostLabel` | region / host DNS label check |
| `parseURL` | URL → struct; rejects non-http(s), rejects queries |
| `substring` | (start, stop, reverse); returns null out-of-range |
| `uriEncode` | Smithy strict RFC-3986 encoding (via reuri's awssig profile) |

## Generated code shape

A service's `endpoint_rules` proc at runtime looks like (simplified):

```tcl
apply {params {
    array set p $params
    set l {<dedup-leaves>}       ;# common endpoint templates
    set e {<dedup-errors>}       ;# common error messages
    try {
        if {aws_b([info exists p(Endpoint)])} {
            _r {<endpoint template>}
        } elseif {!([info exists p(Region)]) && [_a PartitionResult aws.partition svc us-east-1]} {
            ...
        } elseif {...} {
            ...
        }
        throw {AWS ENDPOINT_RULES} {Could not resolve endpoint}
    } on return template {
        ...post-processing...
    } trap terr {errmsg options} {
        throw {AWS ENDPOINT_RULES} [::aws::template $errmsg [array get p]]
    }
} ::aws::_fn} $params
```

Key helpers used by generated code:

- `aws_b(expr)` — math function that coerces any value (JSON
  primitives, JSON valid/invalid, empty, etc.) to a boolean. Handles
  JSON null, JSON primitives, non-JSON strings.
- `_a <var> <cmd>` — runs cmd; on success, stores result in `p($var)`
  and returns 1 iff result is truthy (non-null, non-empty, non-false).
  On error returns 0. The truthy rule lets conditions short-circuit
  correctly when getAttr returns the empty string for a missing element.
- `_e <msg> <istemplate> ?<lookup>?` — emits a rule-tree error leaf.
  With `istemplate` the error message is subject to template
  substitution against the `p` array.
- `_r <template>` / `_r <idx> <table>` — emits a successful endpoint
  leaf; `$table` allows deduping identical templates across the rule
  set.

## Gotchas fixed in this code base

- `aws.partition` must *fall back* to the `aws` partition when no
  region matches, not return null. Several s3/codecatalyst rules
  depend on this (they check `stringEquals(partition.name, "aws")`
  *after* calling aws.partition, so the call must succeed even for
  invalid regions; the DNS validation happens in a separate branch).
- `aws.partition` also needs to check *both* `endpoints.json`'s region
  regex / service list *and* `partitions.json`'s `regions` dict (for
  aws-global, etc.).
- `aws.parseArn` returns null when partition or service or resource is
  empty (matches botocore's behaviour for kinesis ARN with missing
  partition).
- `getAttr` on an empty base (bare index like `[0]`) indexes the Tcl
  list directly. This is specifically for stringArray params (e.g.
  dynamodb's `ResourceArnList`) which arrive as Tcl lists, not JSON.
  Rule-engine-produced values (partition results, parseURL outputs)
  are JSON objects and use the `name[N]` form.
- `substring` takes (start, stop, reverse), not (start, length). Get
  this wrong and S3Express bucket-suffix detection breaks (the
  `--x-s3` test).
- `_a` treats empty-string / JSON null / `false` as falsy. Early
  versions didn't, and codecatalyst's default-region rules passed
  through the wrong branch.
- `compile_conditions` wraps each `&&`-joined operand in `aws_b()` so
  fn results that are JSON objects (aws.parseArn, parseURL) collapse
  to booleans. Without this, `a && b` where `a` returned a JSON object
  would error instead of being truthy.
- Short-circuit `&&` evaluates the second operand only if the first
  is false (at runtime). But Tcl's expr parses both operands at
  compile time, so using `$p(X)` before `[info exists p(X)]` still
  errors. The generated post-processing `credentialScope` lookup
  explicitly guards on `[info exists p(Region)]` to avoid this.

## Partition data wiring

At build time, we read both `endpoints.json` and `partitions.json`.
The service module embeds them via a compressed `aws::_load_ziplet`
that unpacks into `::aws::endpoints` and `::aws::partitions` when
`package require aws::endpoints` runs. `aws.partition` uses both —
`endpoints.json` for the region regex / service endpoint list, and
`partitions.json` for the regions dict and `outputs` dict with the
`dnsSuffix`, `supportsFIPS`, etc.

## Tests

`tests/endpoint_rules.test` runs every test case in
`botocore/tests/functional/endpoint-rules/*/endpoint-tests-1.json` —
13882 cases, currently all passing. If you change anything in
compile_endpoint_rules / compile_arg / compile_conditions / compile_rules
or any of the `aws::_fn::*` helpers, always re-run it.
