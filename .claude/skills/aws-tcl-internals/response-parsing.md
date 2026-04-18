# Response parsing

Responses are decoded differently per protocol and per-op success-vs-
error. This page covers both paths.

## Success-path decoding

### query / ec2 / rest-xml (pre-compiled)

`compile_xml_transforms` in **build.tcl** walks the output shape at
build time and produces:

- A **fetchlist** — a list of 5-tuples
  `{<slot#> <typekey> <xpath> [<sub-fetchlist>] [<template>]}`
- A **template** — an rl_json template with `~J:$slot#` markers that
  get replaced by the fetchlist results

At runtime (generated op body), fetchlist extraction happens and the
template is applied. Result is rl_json.

Typekeys: `s` string, `n` number, `b` boolean, `c` timestamp, `l` list,
`t` structure, `m` map, `x` blob.

Lists have both a fetchlist element (saying "extract all matching
nodes") and a recursive sub-fetchlist + sub-template for each element.
Maps are similar but with key+value handling.

**The non-flattened-list default xpath**: `$source/member`. Get this
wrong and every non-flattened list decodes as an empty array (this was
the cloudformation `list_stacks` bug). See the `elemname` logic around
line 187 of `build.tcl` — the default when member has no locationName
and the list isn't flattened is literal `"member"`.

### rest-xml (lazy)

rest-xml uses `_handle_xml_resp` at runtime, which calls the recursive
`_build_resp_frag` in aws.tcl. Same default-xpath rule applies —
maintained separately in `_build_resp_frag`'s `list` branch. Both
places must agree.

### json / rest-json (pre-compiled)

The JSON response is loaded directly as the result; no per-op
deserialization logic needed. The op's return value is the parsed
rl_json of the response body.

Shape-aware post-processing (e.g. converting timestamps back from
epoch integers to ISO strings) is **not** currently done — users get
the raw JSON form.

### Headers in responses

For shapes with members having `location: header` / `location: headers`,
`compile_output` builds a `header_map` used at runtime to hoist header
values into the response object at their top-level keys.

## Error-path decoding

All protocols route non-2xx responses through `::aws::helpers::_aws_error`
in aws.tcl. It sniffs the body shape:

1. Empty body → throw `[list AWS <status>]` with generic message.
2. Body starts with `{` → JSON error:
   - If `code` key present: `{AWS <code> <x-amzn-requestid> "" []}` with
     `message` as error message.
   - Else if `__type` key present: same with `__type` as the code.
   - Else if `message` key: `{AWS <x-amzn-errortype or "<unknown>"> ...}`.
   - Else log + throw generic.
3. Otherwise parse as XML and inspect the root:
   - `<Response><Errors><Error>...</Error></Errors><RequestID>...</RequestID></Response>`
     → ec2 format, errorCode `{AWS <Code> <RequestID> "" <details>}`.
     Note: `RequestID` with capital-D-capital-D in ec2, vs `RequestId`
     in the standard rest-xml/query form.
   - `<Error><Code>...</Code><Message>...</Message>...</Error>` → standard
     rest-xml / query, errorCode `{AWS <Code> <RequestId> <Resource> <details>}`.
   - `<ErrorResponse><Error>...</Error><RequestId>...</RequestId></ErrorResponse>`
     → cloudformation / query wrapper, errorCode
     `{AWS <Code> <RequestId> "" <details>}`. Unwraps `Error` the same
     way as the top-level `<Error>` case.
   - Anything else → log + throw generic.

The `details` tail is a key-value list of every child node under the
Error element, preserving things like `BucketName`, `Key`, `HostId`
which aren't in the standard fields.

For SignatureDoesNotMatch errors, `_aws_error` also emits a debug-log
comparison of our canonical request bytes vs AWS's, to help sigv4
debugging.

## The `__type` namespace-qualified form

DynamoDB and some other services return `__type` values like
`com.amazonaws.dynamodb.v20120810#ResourceNotFoundException`. Our
errorCode includes the full qualified form; test error-code matchers
should be glob-permissive:

```tcl
-errorCode {AWS *#ResourceNotFoundException *}
```

## Adding a new error shape

Per-operation error shapes (declared in the op's `errors` list) get
their own per-exception throw-handler generated in the service's
`_errors` namespace. `_aws_error` doesn't need to know about per-op
errors — it just throws, and the generated op's `try`/`trap` handler
catches by errorCode and re-throws with service-specific tagging if
needed.

## Streaming / binary response bodies

Not supported yet. Would need a bypass in `_service_req` that avoids
running the response through the XML/JSON parsers and returns the raw
body instead.
