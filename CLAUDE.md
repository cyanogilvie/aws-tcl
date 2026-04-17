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
- `testing.md` — per-file tests, constraints, hazards

Forward-looking (not yet implemented):

- `pagination.md` — how to add pagination using botocore's
  paginators-1.json spec
- `cbor.md` — how to add native smithy-rpc-v2-cbor support alongside
  the json fallback

## Environment

- Primary test target: Tcl 9 at `/opt/tcl9g/bin/tclsh9.0`
- Build: `rm -rf tm && make -e tm TCLSH=/opt/tcl9g/bin/tclsh9.0`
- Test: run per-file with
  `tclsh9.0 tests/all.tcl -load "apply {ver {source tests/load_self.tcl}} 2.0a19" -file <name>`
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
- `tests/units.test` — 61 unit tests of primitives
- `tests/integration.test` — live-AWS tests gated by credentials /
  account-alias constraints

Green baseline: all tests pass per-file (known cross-contamination
when running the whole suite in one process — that's a test-harness
issue documented in `testing.md`).
