---
name: aws-tcl-internals
description: Deep knowledge of how the aws-tcl package works internally — shape parsing, the compile_input pipeline, per-protocol code paths (query/ec2/rest-xml/json/rest-json), response parsing, rule-engine primitives, and the rewriter transform system. Use this when adding or debugging service features, extending protocol support (smithy-rpc-v2-cbor, pagination), investigating serialization issues, or changing any of the build.tcl / aws.tcl machinery.
---

# aws-tcl internals guide

This skill captures the mental model you need to work on aws-tcl without
rediscovering it each time. The package is a Tcl AWS SDK generated from
botocore's JSON service definitions. Shape parsing and code generation are
complex and surprising in specific, non-obvious ways.

## When to read what

Start with `architecture.md` for the high-level layout, then pick the page
matching the task:

| Reading | When |
|---|---|
| `architecture.md` | orientation, build/runtime flow, where code lives |
| `shapes.md` | understanding member attributes (`locationName`, `jsonName`, `flattened`, `payload`, `document`, etc.) |
| `compile-input.md` | touching request-body serialization; adding a protocol; debugging nested shape handling |
| `transforms-and-rewriter.md` | blob base64, NaN/Infinity floats, timestamp formats, jsonName rename, nested-value transforms |
| `protocols.md` | per-protocol quirks (query `.member.N`, ec2 capitalization, rest-xml XML trees, json/rest-json body assembly) |
| `response-parsing.md` | fixing response decoding; handling a new response shape type; changing error classification |
| `rule-engine.md` | endpoint_rules bugs; adding rule-engine fn helpers |
| `testing.md` | writing new tests; understanding the test harness; tcltest gotchas |
| `pagination.md` | adding pagination support (planned, not implemented) |
| `cbor.md` | implementing smithy-rpc-v2-cbor (planned, not implemented) |

## Critical design decisions to respect

Two principles that should not be silently reversed:

1. **JSON is the native complex-value format for json/rest-json/json_1_0
   services.** Nested structures/lists/maps come in as JSON fragments via
   `~J:argname`, not as Tcl dicts. See `protocols.md` for rationale. The
   rewriter transforms those fragments in place — extend the rewriter,
   don't propose unifying all protocols on Tcl-native input.

2. **The endpoint-rules rule engine is generated code, not interpreted.**
   `compile_endpoint_rules` in `build.tcl` produces a Tcl proc body that
   evaluates the rule tree directly. Helpers `_a` / `_e` / `_r` / `aws_b`
   in `aws.tcl` / `aws::_fn` make the generated code terse. Don't
   interpret rules at runtime — compile them.

## Test landscape

Per-file run is always clean. Running the whole suite in one process has
known cross-contamination (common.tcl does `namespace delete ::aws`), so
CI / development runs should be per-file:

```
for f in tests/*.test; do
    /opt/tcl9g/bin/tclsh9.0 tests/all.tcl \
        -load "apply {ver {source tests/load_self.tcl}} 2.0a19" \
        -file "$(basename $f)"
done
```

Running protocol_vectors.test is the best smoke for serialization changes —
236/236 is the current green baseline. endpoint_rules.test (13882 cases)
covers rule engine. integration.test gates live-AWS tests behind the
`aws_creds` / `rl_aws_account` constraints.

## Environment notes

- Tcl 9 at `/opt/tcl9g/bin/tclsh9.0` is the primary test target.
- botocore is a git submodule at `botocore/`; currently pinned to v1.42.90.
- Build: `rm -rf tm && make -e tm TCLSH=/opt/tcl9g/bin/tclsh9.0`.
- rl_json source: `~/git/rl_json` (see the rl_json memory).
- cbor source: `~/git/tcl/cbor` (when implementing smithy-rpc-v2-cbor).
