# smithy-rpc-v2-cbor (planned, not yet implemented)

Three services currently declare `smithy-rpc-v2-cbor` as their primary
protocol: `cloudwatch`, `interconnect`, `arc-region-switch`. All three
list `json` (plus `query` for cloudwatch) as a fallback in
`metadata.protocols`, and our build-time protocol-selection fallback
logic routes them through `json` today. That works *iff* AWS keeps
honouring the JSON alternative on the wire, which they've signalled
they may not forever.

This page captures what a native cbor implementation needs so it can
be bolted on without rediscovery.

## Protocol on the wire

Per the Smithy RPC-v2-cbor spec:

- **Method**: always `POST`.
- **URL path**: `/service/<targetPrefix>/operation/<OperationName>`.
  No query string. `targetPrefix` comes from `metadata.targetPrefix`
  just like json-1.1.
- **Headers**:
  - `smithy-protocol: rpc-v2-cbor`
  - `Accept: application/cbor`
  - `Content-Type: application/cbor` (present iff there's a body)
  - optional event-stream variant headers; ignore for v1
- **Body**: CBOR-encoded representation of the input structure.
- **Response**: CBOR-encoded body; `Content-Type: application/cbor`.

The CBOR on the wire follows fairly standard CBOR rules, but with a
specific representation for special types:

- Integers → CBOR unsigned / negative integer (type 0 / 1).
- Floats → CBOR float (type 7, subtypes 25/26/27). NaN / Infinity use
  the natural CBOR encoding (not JSON string quoting).
- Strings → CBOR text string (type 3).
- Blobs → CBOR byte string (type 2). **Not** base64 like JSON bodies.
- Booleans → CBOR simple value (20 / 21).
- Null → CBOR null (simple value 22). Same "strip nulls before
  sending" rule as JSON.
- Timestamps → CBOR tag 1 (epoch) wrapping a float (seconds since
  epoch). No ISO-8601 option.
- Arrays → CBOR array (type 4).
- Maps → CBOR map (type 5).
- Structures → CBOR map with member serialization names as keys.
  Same `jsonName` / `locationName` rules as json (jsonName wins).
- Documents → CBOR value of whatever natural type matches (same
  "accept any JSON value" semantic, but encoded as the equivalent CBOR).

Reference: <https://smithy.io/2.0/additional-specs/protocols/smithy-rpc-v2.html>

## cbor package (Tcl)

Source: `~/git/tcl/cbor`. Provides:

- `cbor::encode <type> ?<args>...?` — low-level encoders
- `cbor::template <json-template> <dict>` — JSON-style template that
  produces CBOR bytes. Shape-wise similar to rl_json's `json template`.
- `cbor::decode <cbor-bytes>` — parse to a Tcl/rl_json-compatible form
- `cbor::extract / ::get / ::pretty` — navigate/inspect

The template-style encoder is the direct analogue of rl_json's template,
so much of `compile_input` can be reused almost verbatim, just swapping
the output step from `json template` to `cbor template`.

## Implementation path

### 1. Recognise the protocol

In `build.tcl`, remove `smithy-rpc-v2-cbor` from the "fall back to
supported" branch and add a new bucket:

```tcl
set by_protocol {
    json        {}
    rest-json   {}
    query       {}
    rest-xml    {}
    ec2         {}
    smithy-rpc-v2-cbor {}
}
```

### 2. Code generation

Create a cbor generator loop (parallel to the existing json/rest-json/
query loop). Most of it mirrors the json path:

```tcl
foreach service_def [dict get $by_protocol smithy-rpc-v2-cbor] {
    # compile_input as usual — shapes and transforms are identical
    # to json, but we emit a cbor template instead of a json template
    set t [aws::build::compile_input \
        -protocol cbor \
        ... \
        -transforms transforms]
    # body assembly at runtime: cbor template $t $args
    # URL path: /service/$targetPrefix/operation/$op
    # Headers: smithy-protocol, Accept, Content-Type
}
```

compile_input needs a `-protocol cbor` branch. Existing shape handling
(rewriter, transforms) applies almost verbatim with two changes:

- **Blobs are raw, not base64**. The `blob` transform kind emits the
  raw bytes; `cbor template`'s blob substitution marker emits a CBOR
  byte string. No base64 wrapping.
- **Timestamps are always unixTimestamp-ish** (CBOR tag 1 + float) —
  shape-level `timestampFormat` is ignored on the wire. We normalise
  everything through `_tx_ts_epoch` and emit a CBOR tagged float.

### 3. Runtime

Add a body-assembly branch in `_service_req`:

```tcl
} elseif {$protocol eq "smithy-rpc-v2-cbor"} {
    set body [uplevel 1 [list cbor template $template]]
    set content_type application/cbor
    lappend headers smithy-protocol rpc-v2-cbor
    lappend headers Accept application/cbor
}
```

Response handling: decode the CBOR body to rl_json (via
`cbor::to_json` or similar) so downstream consumers see the same
rl_json-shaped result they do for json/rest-json ops.

### 4. Error responses

Errors in rpc-v2-cbor are CBOR-encoded. Format:

```
{
    "__type": "com.example.svc#MyError",
    "message": "the error message",
    ...custom error fields...
}
```

(Encoded as CBOR map). `_aws_error` sniffs `{` for JSON today; for
cbor we need a separate error-path branch that decodes CBOR first,
then routes through the same classification logic.

### 5. Event streams (later)

rpc-v2-cbor supports AWS event streams (`application/vnd.amazon.eventstream`
Content-Type variant). Out of scope for v1 — note that the
`operation_model.has_event_stream_output` check in botocore signals
ops that need it. Skip them in v1 and re-route to the fallback
protocol.

## Tests

`botocore/tests/unit/protocols/input/smithy-rpc-v2-cbor.json` and the
output counterpart exist — 15 + more cases. They include
`smithy-rpc-v2-cbor-non-query-compatible.json` and `-query-compatible`
variants.

Add a `cbor` branch to `protocol_vectors.test`'s dispatcher: synthesize
the service_def, run compile_input with `-protocol cbor`, assemble the
body via `cbor template`, compare to the reference CBOR bytes.

Test bodies in the fixtures are given as base64-encoded CBOR strings in
the `serialized.body` field. Decode with `binary decode base64` before
byte-comparing. CBOR has canonical-encoding rules — both the reference
and our output should match byte-for-byte *if* we use the canonical form
(integers in minimum-length encoding, map keys sorted, etc.). The cbor
package probably handles canonicalization; if not, we may need a
canonicalize pass before comparing.

## Scope estimate

Starting fresh with the existing shape-walk as a model: probably a day
of focused work. The hard part is response decoding (decoding CBOR back
to rl_json for consumers; less formally specified) and the transform
layer for CBOR-specific rules (blobs as raw, timestamps as tagged
floats). The request side is mostly "swap json template for cbor
template" given compile_input's current architecture.

## Why implement it

Aside from future-proofing, cbor bodies are smaller and decode faster
than JSON. For services with large request/response shapes (cloudwatch
especially — Metrics API) the bandwidth savings are meaningful.
