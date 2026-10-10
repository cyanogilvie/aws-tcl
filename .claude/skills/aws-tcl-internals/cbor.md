# smithy-rpc-v2-cbor

Implemented natively, but used only by services whose `metadata.protocols`
offers nothing else we support (currently `cloudwatchomni`,
`eventbridgev2`, `partnercentral-revenue-measurement`).  The ~22 services
that list cbor first *and* a json fallback (cloudwatch, ...) still build
as `json`: the native path needs Tcl 9 + jitc + cbor at runtime, and the
json path doesn't.  To move one over, change the protocol selection in
`build_aws_services` (build.tcl).

## Shape of the implementation

It is the json pipeline with a different last step on each side:

```
request:  parse_args → transforms / rewriter → json template → null strip
          → _cbor_encode $bodydoc $input_shape $cbor_shapes   (cbor_glue.c)
response: _cbor_decode $body → the rl_json value a json service returns
errors:   _aws_error decodes a CBOR body to the same {"__type","message"}
          document and falls into its JSON branch
```

- **build.tcl**
  - `by_protocol` has a `smithy-rpc-v2-cbor` bucket, generated in the same
    loop as json / rest-json / query / ec2.
  - `compile_op`: `POST /service/<targetPrefix>/operation/<Op>`,
    `-c application/cbor`, headers `smithy-protocol: rpc-v2-cbor`,
    `Accept: application/cbor` (+ `x-amzn-query-mode: true` with
    `awsQueryCompatible`), `-cs <input shape>`.  No input shape → no body
    and no Content-Type (the `t {}` no-input rule, as for rest-json).
  - `compile_cbor_shapes` emits `variable cbor_shapes` into the service
    namespace: shape name → descriptor (grammar at the top of
    `cbor_glue.c`).  Structure keys are serialization names: `locationName`
    else the member name.  **jsonName doesn't apply** to rpc-v2-cbor.
- **aws.tcl**
  - `compile_input` treats cbor like json for body members; timestamps are
    always `unixTimestamp` (`ts_epoch`) whatever `timestampFormat` says.
  - `build_rewriter_spec`: same timestamp rule, and no jsonName renames.
  - `_service_req -cs`: the body is `_cbor_encode $bodydoc $cbor_shape
    $cbor_shapes`; a non-empty response body is `_cbor_decode`d.
  - `_aws_error`: `content-type: application/cbor` → decode, then the JSON
    branch (which now also accepts `Message` as well as `message`).  For
    cbor only, an `x-amzn-query-error` header ("Code;Fault") overrides
    `__type` (query-compatible services).
  - `_cbor_init` (lazy, first use): `package require jitc 0.8`, `cbor
    1.2`, reads `cbor_glue.c` from beside aws.tcl (the zipfs root), and
    `jitc::bind`s `::aws::_cbor_encode` / `::aws::_cbor_decode` over the
    placeholder procs.  Missing packages → `{AWS UNSUPPORTED cbor}`.
- **cbor_glue.c** (repo root, packed into the zipfs next to aws.tcl; an
  input of the `tm` target): C23 + `defer`, compiled by jitc with
  `package` parts for rl_json and cbor (direct linking — jitc can't link
  stub libraries).
  - encode walks the rl_json doc with the shape table: blob → base64
    decode → byte string; timestamp → tag 1 wrapping a float (always a
    float — the Smithy vectors expect it even for whole seconds);
    float/double → float (also `"NaN"` / `"Infinity"` / `"-Infinity"`
    strings, the json protocols' form); everything without a shape
    (documents, unmodeled keys) → RFC 8949 §6.2 generic mapping.
  - decode is generic (no shapes): byte string → base64 string, tag 1 →
    its number, tags 2/3 → bignum number, NaN/±Inf → the strings above,
    other tags transparent, integer map keys → decimal strings.  So
    results match the json protocols' raw-body design (see the
    `json_response_decode_gap` memory): unmodeled members are returned.
  - Workaround in it: jitc 0.8.6's libslimcc evaluates `NAN` and
    `INFINITY` to 0 — use `nan("")` / `HUGE_VAL`.

## Wire details worth knowing

- Bodies are CBOR maps; definite lengths on our side, either accepted
  from the server.
- Floats: we send the shortest exact width (cbor's `CBOR_EmitFloat`);
  botocore always sends f32 for float, f64 for double.  Equivalent on the
  wire.
- `_req` routes a signed `Accept` header through rl_http's `-accept`:
  rl_http always writes its own Accept line, so passing it in `-headers`
  sent two and the server's canonical request (`accept:*/*,application/
  cbor`) didn't match our signature.  Any protocol that sets Accept
  benefits.
- Endpoint rules for these services may list `sigv4a` (with a
  `signingRegionSet`) before `sigv4`; `_eir` prefers `sigv4` when both are
  offered.

## Tests

`tests/protocol_vectors.test` runs botocore's
`{input,output}/smithy-rpc-v2-cbor*.json` (gated by `haveCbor`):

- input: the captured body is compared with the vector's base64 body via
  `vec_cbor_canon` (a jitc helper over the cbor C API producing a
  canonical tree: maps sorted, definite/indefinite alike, float width
  ignored but types and tags kept) and `vec_cbor_equal` (floats also
  equal after rounding to float32).
- output: `_cbor_decode`; expected blobs are base64-encoded and unmodeled
  members dropped from ours (`vec_b64_blobs`, `vec_modeled`) before
  `result_equal`.
- errors: `run_output_error_file` drives the real `_aws_error` with an
  `interp alias` stand-in for the rl_http object; codes are compared on
  the part after `#`.

Live: the three services' list ops, plus cloudwatch reified with the
protocol forced to cbor (GetMetricData exercises tag-1 timestamps and
doubles both ways) worked against AWS on 2026-10-10.

## Not done

- Event streams (`application/vnd.amazon.eventstream`): none of the
  cbor-only services have event-stream operations yet.
- Shape-aware response decoding (it's raw, like json).
