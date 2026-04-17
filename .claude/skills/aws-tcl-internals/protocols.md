# Per-protocol quirks

Five protocols are implemented (`query`, `ec2`, `rest-xml`, `json`,
`rest-json`; `json_1_0` is a minor variant of `json`). Each has its own
wire quirks. This page is the cheatsheet.

## query and ec2

Request body is `application/x-www-form-urlencoded`. No JSON body,
no XML body — everything goes in query-param pairs.

### Action and Version

Every op emits `Action=<OpName>` and `Version=<apiVersion>`.
`compile_input` prepends these at the start of `q` in the generator:

```tcl
if {$protocol in {query ec2}} {
    lappend q Action _a {}       ;# `_a` is populated per-op
    lappend static [list set _a $op]
}
```

### List flattening

Four combinations (see `shapes.md`):

| flat flag | member locationName | wire form |
|---|---|---|
| shape or member `flattened: true` | `X` | `$pref.1=..&$pref.2=..` (ec2 protocol is *always* flat) |
| shape or member `flattened: true` | absent | `$pref.1=..&$pref.2=..` (same) |
| not flattened | `X` | `$pref.X.1=..&$pref.X.2=..` |
| not flattened | absent | `$pref.member.1=..&$pref.member.2=..` |

The ec2 protocol also *capitalizes the first letter* of the serialized
name (or uses `queryName` verbatim if present). `compile_input` handles
this.

### Map flattening

`Prefix.entry.N.key=K&Prefix.entry.N.value=V` when not flattened;
`Prefix.N.key=K&Prefix.N.value=V` when flattened. Key and value names
can be overridden with member `locationName` (the `MapWithXmlName` test
uses `K` / `V` instead of `key` / `value`).

### Value forms on the wire

- Booleans: `true` / `false` (not `1` / `0`). `_flatten_query_param`
  has a `bool` spec branch that emits the right form.
- Blobs: base64, via the `blob` spec branch.
- Timestamps: iso8601 by default, `unixTimestamp` or `rfc822` if the
  shape's `timestampFormat` says so.
- Other primitives: toString.

### Version injection from apiVersion

Services with `apiVersion` in their metadata get a runtime `Version`
param injected. Stored as the `apiVersion` variable in the service
namespace.

## rest-xml

Used by s3, s3control, cloudfront, route53. Request body is XML when
there's an input payload; query-string and URI path handle the rest.

### Lazy compilation

Unlike the other protocols, rest-xml ops are compiled on first use via
the `_compile_rest-xml_op` ensemble-unknown handler. This is because the
pre-compile cost for all s3 ops would be large. The lazy path runs
`aws::build::compile_input` (the version *inside* aws.tcl's `aws::build`
namespace) at first call.

### Body XML construction

`compile_xml_input` produces an "xml add instructions" tree that
`_xml_add_input_nodes` walks to populate a tdom document. There is no
`~J:` / template-based body for rest-xml inputs — XML isn't amenable to
rl_json templates.

### Response parsing

Uses `_handle_xml_resp` at runtime, which walks `_build_resp_frag`
recursively. The classic bug here was the non-flattened-list default
("member" xpath, not the parent name) — fixed in the cloudformation
list-unwrap fix, also in `compile_xml_transforms` (build.tcl) for the
other XML protocols.

## json, rest-json, json_1_0

Request body is JSON. The three differ only in:

- `json` (aws-json-1.1): body is `{...}`, `x-amz-target: <targetPrefix>.<Op>`
- `json_1_0` (aws-json-1.0): same but `content-type: application/x-amz-json-1.0`
- `rest-json`: no `x-amz-target` header; method/URI/location-routed
  members come from the operation metadata

### The ~J: input convention

**Complex-typed members (structures, lists, maps, unions) are passed
as JSON fragments by the caller**, not as Tcl dicts. This is a
deliberate design decision, not a limitation. See the "input_format_decision"
project memory in the memory directory for the reasoning.

`rl_json`'s `json template` with `~J:argname` substitutes the value
verbatim as a JSON fragment. That value must be valid JSON already.
The rewriter layer (transforms-and-rewriter.md) walks *inside* these
JSON fragments to apply member-level transforms (base64-encode blobs,
rename jsonName'd keys, etc.) before substitution.

### Null stripping

After `json template` produces the body, `_service_req` runs a post-
pass that removes keys whose value is JSON null at every level. This
is how absent-from-user-args members disappear from the body — the
template produces null for missing `~S:`/`~N:`/`~J:` variables and
the strip then removes them.

The strip walks the whole tree, so deeply-nested nulls in arrays /
objects also get removed.

### Booleans

Booleans use `~B:argname`, which interprets the var per Tcl's truthy
rules (anything that would enter `if {$x}`'s true branch becomes JSON
`true`). **Do not use `~J:` for booleans** — `~J:` substitutes the
value verbatim as JSON; a Tcl `1` becomes JSON `1` (number), not
`true`.

### Timestamps

JSON bodies default to `unixTimestamp` (epoch integer). Shape
`timestampFormat` overrides. See the transforms doc for the helper
procs.

### Enums

Plain strings with a shape-level `enum` list. We do *not* validate the
user's value against the enum list at runtime; we pass whatever they
send. That's by choice — AWS will reject invalid enums server-side
with a clear error.

Some services (older ones) use member-level `jsonName` to *rename* an
enum-valued member at the wire level (`foo` → `FOO`, `baz` → `_baz`).
That rename is handled by the rewriter, not by any enum-specific
logic.

## Document type

A structure shape with `document: true` means "accept any JSON value
here" — primitive, array, object, anything. The rewriter's
`build_rewriter_spec` short-circuits to `""` (identity) when it sees
the flag, so the user's JSON flows through untouched.

If you see `documentValue: true` in the wire form where the user
passed `true`, that's working. If you see `documentValue: 1`, that
means the template used `~N:` or the value was turned into a Tcl
integer somewhere — investigate.

## Protocol selection (service-2.json)

`metadata.protocol` is the primary protocol. `metadata.protocols` is
an ordered list of fallbacks (newer). `build_aws_services` checks:

1. If `metadata.protocol` is one of our supported set, use it.
2. Otherwise scan `metadata.protocols` for a supported one and use
   that.
3. Otherwise skip the service (logged, not built).

This is how `smithy-rpc-v2-cbor` services (cloudwatch, interconnect,
arc-region-switch) currently build: they fall back to `json`.
Adding native cbor support is documented in `cbor.md`.

## Signing

All current protocols sign with sigv4 (`v4` version). The variant `s3v4`
is used for s3 (double-URL-encoding differences). The `signingName` used
for the credential scope comes from the endpoint rules' `authSchemes`
result, falling back to `endpointPrefix`.

The `-sig_service` to `_service_req` is the signing name. For json
protocols it comes from service metadata; for rest-xml it's resolved
at call time from the endpoint rules' authScheme properties.
