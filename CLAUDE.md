# Notes for Claude Code sessions

## Read this before touching aws.tcl or build.tcl

This package has a lot of non-obvious internal structure — shape
parsing, per-protocol code generation, endpoint rule compilation, the
transforms/rewriter pipeline for body values, the asymmetric handling
of Tcl-native vs JSON-fragment inputs across protocols. Before making
changes, load the skill:

- **Skill**: `aws-tcl-internals` (at `.claude/skills/aws-tcl-internals/`)

Key pages to start with:

- `SKILL.md` — table of contents and orienting info
- `architecture.md` — build/runtime split, directory layout, key procs
- `shapes.md` — every member attribute that matters
- `compile-input.md` — the central shape walk
- `transforms-and-rewriter.md` — per-value transformation layers
- `protocols.md` — what each protocol does differently
- `response-parsing.md` — success and error response decoding
- `rule-engine.md` — endpoint-rules compilation and the runtime helpers
- `pagination.md` — aws foreach / aws lmap, driven by paginators-1.json
- `retry.md` — retry classifier, backoff, per-service rate-limit state (tsv-backed), idempotency-token auto-fill
- `testing.md` — test file layout, constraints, the fixture stack

Forward-looking (not yet implemented):

- `cbor.md` — how to add native smithy-rpc-v2-cbor support alongside
  the json fallback

## Environment

- Primary test target: Tcl 9 at `/opt/tcl9g/bin/tclsh9.0`
- Build: `rm -rf tm && make -e tm TCLSH=/opt/tcl9g/bin/tclsh9.0`
- Test: `make test TCLSH=/opt/tcl9g/bin/tclsh9.0` runs the whole suite in
  one process. Single file: add `TESTFLAGS='-file <name>'`.
- Live-test fixture stack: `make fixtures` deploys + seeds a CloudFormation
  stack in the caller's account with deterministic resources; tests gated
  by the `aws_tcl_fixtures` constraint run against it.
  `make teardown-fixtures` cleans up. See `tests/fixtures/README.md`.
- `botocore/` is a git submodule; currently pinned to v1.42.90
- Related sources (not in this repo):
  - rl_json: `~/git/rl_json` (see memory)
  - cbor: `~/git/tcl/cbor` (for future cbor impl)

## Design decisions worth not re-litigating

See `memory/input_format_decision.md` — nested inputs for json-family
protocols are intentionally JSON fragments, not Tcl dicts. Don't
propose unifying all protocols on Tcl-native input without checking
that memory first.

## Where the invariants live

- `tests/endpoint_rules.test` — 13882 cases from botocore; touches
  rule-engine changes break these loudly
- `tests/protocol_vectors.test` — 236 serialization cases from
  botocore; the best smoke for serialization work
- `tests/units.test` — primitives + retry classifier / backoff /
  Retry-After / UUIDv4 / idempotency-token auto-fill
- `tests/retry.test` — `_aws_req` retry loop end-to-end with a
  programmable mock `_req`
- `tests/pagination.test` — 30 unit + fixture-stack tests of
  `aws foreach` / `aws lmap`
- `tests/integration.test` — live-AWS tests gated by credentials /
  account-alias constraints
- `tests/s3sigv4.test` — live s3 sigv4 path-encoding cases (goes
  through `aws s3 put_object` now; no more workaround)

Green baseline: `make test` passes whole suite in one process
(14283 / 14289 at time of writing; remaining skips are constraint-
gated: rl_aws_account + a handful of known-bug sentinels).

Requires rl_http ≥ 1.22 (for `-connect_timeout` / `-read_timeout`).
In a dev setup where rl_http isn't system-installed, point make/tests
at the dev build via `AWSTCL_EXTRA_TM_PATH=/path/to/rl_http/tm`.
