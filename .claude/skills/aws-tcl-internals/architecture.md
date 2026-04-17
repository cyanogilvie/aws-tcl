# Architecture

## Build/runtime split

- **Build time** (`build.tcl`, invoked by `make tm`): reads
  `botocore/botocore/data/<service>/<version>/service-2.json` +
  `endpoint-rule-set-1.json`, generates one module per service under
  `tm/aws/<service>-<VER>.tm`. The module contains one proc per operation
  (or a lazy-compile stub for rest-xml), plus an `endpoint_rules` proc
  from the rule-set JSON.
- **Runtime** (`aws.tcl`): the base package. Provides `aws` ensemble,
  `_service_req` orchestration, signing (sigv4), response parsing,
  error parsing, and helpers for the generated code to call.

Service modules `package require aws 2` and use helpers from
`::aws::helpers::*` and `::aws::_fn::*`.

## Directory layout (things that matter)

```
aws.tcl                     # base package + rule-engine helpers + compile_input
build.tcl                   # code generator: walks botocore/, writes tm/
Makefile                    # `make tm` drives build.tcl
botocore/                   # git submodule, botocore release (currently 1.42.90)
tm/aws/                     # generated service modules (built artefact, not checked in)
tests/                      # tcltest files; see testing.md
```

## Code generation flow (build.tcl)

1. `build_aws_services` iterates every `botocore/data/*` directory.
2. For each service:
   - Reads `service-2.json`. `metadata.protocol` decides the protocol
     bucket (json / rest-json / query / rest-xml / ec2). If it's
     `smithy-rpc-v2-cbor`, fall back to the first supported protocol in
     `metadata.protocols` (see `cbor.md`).
   - Reads `endpoint-rule-set-1.json` and compiles it to a Tcl proc body
     via `compile_endpoint_rules` → `compile_rules` → `compile_arg`.
   - For each operation, calls `aws::build::compile_input` to produce
     the request-side artefacts (template_obj, query_map, uri_map,
     header_map, payload hint, transforms, builtins).
   - For response handling, either:
     - query/ec2/rest-xml: pre-compiles an xpath fetchlist +
       rl_json template via `compile_xml_transforms` (in build.tcl).
     - json/rest-json: uses runtime `_build_resp_frag` (in aws.tcl).
   - Writes out a per-op proc that reduces at runtime to:
     `parse_args <argspec> → static prep lines → _service_req <args>`.
3. Output is either plain .tm, compressed ziplet, or compressed brlet
   depending on `MODE`.

## Runtime flow (aws.tcl `_service_req`)

1. Generated proc calls `_service_req -q $query_map -c $content_type ...`.
2. `_service_req` reads caller's local vars (the parse_args'd args).
3. Runs endpoint rules (`$ei` is a small lambda that calls the service's
   `endpoint_rules` proc) to pick hostname + signing region + signing
   name.
4. Applies URI template substitutions from `uri_map`.
5. Walks `header_map` to build HTTP headers.
6. Walks `query_map` — for query/ec2 this produces the form-URL-encoded
   body via `_flatten_query_param`; for rest-* it produces query-string
   params.
7. Applies per-shape `transforms` (blob base64, float NaN handling,
   timestamp format, rewriter) before the body template is evaluated.
8. Builds the body: either form-URL-encoded, JSON (via
   `json template $template_obj`), or XML (via `compile_xml_input`).
9. Calls `_req` which signs (sigv4) and issues `rl_http`.
10. Dispatches the response to `handleresp` (XML protocols) or the
    generated op body (JSON protocols).
11. Errors unwind through `_aws_error` which sniffs the response body
    shape (JSON / `<Error>` / `<Response><Errors><Error>`) and throws
    with `errorCode` `{AWS $code $requestid $resource $details}`.

## Per-protocol dispatch

The per-protocol generator at build.tcl ~line 789 iterates
`by_protocol` buckets (json, rest-json, query, ec2 share a loop;
rest-xml has its own lazy-compile path that reuses `aws::build::compile_input`
at first call). The per-protocol differences mostly live in:

- `compile_input` (one branch per `location` + protocol combo) in aws.tcl
- `compile_xml_transforms` (response decoding for query/ec2/rest-xml)
- `_service_req` body-assembly branching (`content_type` check picks
  query vs JSON vs template)
- `_aws_error` (error-body format sniffing)

## Key procs at a glance

| Proc | Where | Purpose |
|---|---|---|
| `aws::build::compile_input` | aws.tcl | the central shape walk for request inputs |
| `aws::build::compile_query_spec` | aws.tcl | query/ec2 flatten spec |
| `aws::build::build_rewriter_spec` | aws.tcl | nested-value transform spec for JSON protocols |
| `aws::_flatten_query_param` | aws.tcl | runtime url-form body from Tcl value + spec |
| `aws::_tx_rewrite` | aws.tcl | runtime walk of nested JSON fragments |
| `aws::_apply_tx` | aws.tcl | dispatcher for per-member transforms |
| `aws::_service_req` | aws.tcl | the main runtime orchestrator |
| `aws::helpers::_req` | aws.tcl | sign + HTTP call |
| `aws::helpers::sigv4` | aws.tcl | AWS Sig v4 signer |
| `aws::helpers::_aws_error` | aws.tcl | response body → AWS error exception |
| `aws::_handle_xml_resp` | aws.tcl | rest-xml response decoder |
| `aws::_build_resp_frag` | aws.tcl | recursive XML → JSON for rest-xml |
| `compile_xml_transforms` | build.tcl | xpath fetchlist + template for static responses |
| `aws::build::compile_xml_transforms` | aws.tcl | same, for rest-xml lazy compile |
| `aws::build::build_aws_services` | build.tcl | top-level driver |
| `aws::build::compile_endpoint_rules` | build.tcl | rule-set-1.json → Tcl proc body |
| `aws::_fn::aws.partition` / `aws.parseArn` / ... | aws.tcl | rule-engine primitives |

There are two `compile_xml_transforms` procs — one at global scope in
build.tcl (used during module generation), one in `aws::build` inside
aws.tcl (used by rest-xml's lazy compile path). Keep them in sync if you
change one; they were both buggy around non-flattened-list defaults
before the `member` fallback fix landed.
