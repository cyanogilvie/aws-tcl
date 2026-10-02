# Testing

Test files live in `tests/`, all using `tcltest`. Primary target is Tcl 9
at `/opt/tcl9g/bin/tclsh9.0`.

## Running

Build + test go through meson (see the repo's CLAUDE.md for the
standard build dirs). Whole suite, in one process:

```
PKG_CONFIG_PATH=/opt/tcl9g/lib/pkgconfig meson setup build9g -Dtestmode=true
meson compile -C build9g
meson test    -C build9g
```

Single file / subset:

```
TESTFLAGS='-file pagination.test' meson test -C build9g
TESTFLAGS='-match pagination-1.*' meson test -C build9g
```

`tools/runtests.tcl` drives `tests/all.tcl`, prepending
`$builddir/tm` to `tcl::tm::path` so the freshly built
`aws-<VER>.tm` (with the per-service modules in its appended zipfs)
is what gets loaded. `meson test` rebuilds the tm first, so there is
no separate rebuild step after aws.tcl / build.tcl changes.

## Test files (current)

| File | Kind | Notes |
|---|---|---|
| `units.test` | offline unit tests | primitives — getAttr, substring, parseArn, partition, _a, flatten, error parsers, retry classifier, backoff, Retry-After parser, UUIDv4, idempotency auto-fill |
| `retry.test` | offline unit tests | 9 end-to-end tests of `_aws_req`'s retry loop with a programmable mock `_req` — all throttle/transient codes, socket errors, exhaustion, Retry-After |
| `sigv4a.test` | offline unit tests | 17 tests: SigV4-A KDF scalar derivation, full-signing output shape (algorithm, scope-without-region, X-Amz-Region-Set), end-to-end signature-verifies-against-derived-pubkey |
| `signing_vectors.test` | offline, from fixtures | 74 tests driven by AWS's published SigV4 / SigV4-A test vectors in aws-c-auth/tests/aws-signing-test-suite. v4 cases check canonical request + STS + signature bit-exactly; v4a cases check canonical request + STS bit-exactly, verify the produced signature against the expected public key from public-key.json, and also cross-check that our KDF derives the same public key |
| `endpoint_rules.test` | offline, from fixtures | 13882 tests from botocore/tests/functional/endpoint-rules |
| `protocol_vectors.test` | offline, from fixtures | 236 serialization tests driven by botocore/tests/unit/protocols/input/*.json (query/ec2/json/json_1_0/rest-json) |
| `pagination.test` | mixed | 23 offline unit tests of `aws foreach` / `aws lmap` against a fake service; 6 live tests gated by `aws_tcl_fixtures`; 1 legacy rl_aws_account test |
| `integration.test` | online, gated | smoke / rl-only tests against live AWS |
| `account.test`, `cloudformation.test`, `dynamodb.test`, `ec2.test`, `logs.test`, `rest-xml.test`, `s3sigv4.test`, `sqs.test`, `sts.test` | online, service-specific | narrow integration tests |

## Constraints

Gate network-dependent tests on:

- `aws_creds` — true when `aws::helpers::get_creds` returns (i.e. a
  credential source resolves). Used for all live-AWS tests. Defined in
  `integration.test` and `pagination.test`.
- `aws_tcl_fixtures` — true when `aws_creds` *and* the test fixture
  CloudFormation stack exists and is in a complete state. Defined in
  `pagination.test` via `tests/fixtures.tcl`. The stack provides
  deterministic IAM policies / SSM parameters / log groups / seeded S3
  objects for exact-count assertions. Deploy with `make fixtures`,
  teardown with `make teardown-fixtures`. See `tests/fixtures/README.md`.
- `rl_aws_account` — true when `aws_creds` *and*
  `iam list_account_aliases` returns `"rubylane"` in its list. Used for
  tests that depend on Ruby Lane-specific deployed resources (lots of
  stacks, specific lambdas, etc.). The account id never leaves the local
  runtime — we only check the alias. Being superseded by
  `aws_tcl_fixtures` for new tests; kept for a few rubylane-only legacy
  checks.
- `knownBug` — skips tests pending a specific fix. Used sparingly.

These are test-level gates; the tests themselves do no writes and no
state mutation on external state, except the fixture-stack seed helpers
(which write only into the stack's own bucket).

## The fixture stack

`tests/fixtures/aws-tcl-test.json` is a CloudFormation template that
stands up free-tier resources with deterministic names: 1 S3 bucket,
12 IAM managed policies, 12 SSM parameters, 3 CW log groups. Stack
outputs expose the concrete names/prefixes. `tests/fixtures.tcl`
caches those outputs and exposes them as `[fixture_stack_output Key]`
to tests.

`tests/fixtures/seed_objects.tcl` puts a curated set of S3 objects into
the bucket after stack creation — keys chosen to exercise sigv4 signing
edge cases (spaces, UTF-8, reserved chars, brackets, parens, tilde) and
to produce a useful mix of Objects + CommonPrefixes when listed with
`-delimiter /`. `tests/fixtures/empty_bucket.tcl` flushes the bucket
before stack deletion (CloudFormation can't delete a non-empty bucket).

Gotchas learned the hard way:

- SSM parameter names whose first hierarchy element starts with `aws` or
  `ssm` are reserved and return `AccessDeniedException` on create AND
  delete — effectively zombie resources. Keep all parameter paths under
  a neutral prefix like `/fixtures/…`.
- CloudFormation's error response is `<ErrorResponse><Error>…</Error></ErrorResponse>`
  (unlike S3's top-level `<Error>` or EC2's `<Response><Errors><Error>`).
  Handled in `_aws_error`, aws.tcl:605.

## Test style

Prefer tcltest's built-in expectation options over `catch {...}`:

```tcl
# Bad
test foo {} -body { catch {something} } -result 1

# Good
test foo {} -body { something } -returnCodes error -result expected
```

For matching error codes:

```tcl
-returnCodes error -errorCode {AWS NoSuchBucket *}       ;# glob; no -match needed for errorCode
-returnCodes error -match regexp -result {AWS: .*}       ;# regexp only applies to -result
```

**Important**: `-errorCode` is always glob-matched (via `string match`),
regardless of `-match`. Only `-result` honours `-match regexp` /
`-match glob`.

## Cleanup hygiene

tcltest runs `-setup`, `-body`, `-cleanup` in the *global* namespace,
so variables set in a test persist to later tests. Add `-cleanup {unset
-nocomplain X Y Z}` to any test that sets vars — failure mode is
otherwise hysteresis where reordering tests changes outcomes.

## protocol_vectors.test harness

This is the most valuable test file for serialization regressions.
It drives botocore's test vectors at
`botocore/tests/unit/protocols/input/<protocol>.json` through the real
`compile_input` → runtime transforms → `json template` pipeline and
compares byte-for-byte against the reference outputs.

Key pieces:

- `compile_case` — synthesizes a fake `service_def` from the test
  entry's shapes + metadata, calls `compile_input`, returns
  `{params_spec query_map template_obj transforms body payload_type
   protocol}`.
- `assemble_query_body` — drives `_flatten_query_param` + prepends
  `Action=&Version=` for query/ec2.
- `assemble_json_body` — applies transforms (both scalar and rewrite
  kinds), calls `json template`, strips nulls.
- `diff_query_body` — compares URL-encoded pairs, order-independent.
- `diff_json_body` + `json_equal` — recursive JSON equality ignoring
  object key order.

When adding a new transform kind, update both `assemble_json_body`'s
switch and `tx_kind`/`wants_json` logic so the harness picks the right
value form (Tcl for scalar transforms; JSON for the `rewrite` kind).

## Unsupported test cases

`protocol_vectors.test` has an `unsupported_cases` list that filters
tests for features we explicitly don't implement:

- Request compression (`SDKAppliedContentEncoding*`,
  `SDKAppendsGzipAndIgnores*`, `SDKAppendedGzipAfterProvided*`) — would
  need gzip support in `_service_req`.
- Idempotency token auto-fill (`*IdempotencyTokenAutoFill*`) — would
  need a UUID helper and per-member opt-in.
- Endpoint-trait host labels (`*EndpointTraitWithHostLabel`) — would
  need support for the `endpoint.hostPrefix` operation trait.
- `EmptyQueryLists` — AWS query protocol's empty-list sentinel (emit
  `ListArg=` with empty value).

Keep the list tight — every entry is a TODO.

## Adding a new test

For a new unit test, put it in `units.test` grouped with similar
primitives. For a new service-level integration test, put it in
`integration.test` under the appropriate constraint. Avoid creating
per-service test files unless there's a specific regression
justifying it (the old `lambda.test` was retired because its hard-
coded assertion was superseded by `smoke-lambda-list_functions` in
`integration.test`).

For a new protocol-vector-style test (e.g. if you implement a new
protocol and want to drive its test vectors), extend
`protocol_vectors.test`'s dispatcher with a new branch.
