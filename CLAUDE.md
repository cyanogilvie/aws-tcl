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
- Build + test happen through meson (the Makefile is gone except for
  the fixture-stack lifecycle). Standard dev invocation:

  ```sh
  PKG_CONFIG_PATH=/opt/tcl9g/lib/pkgconfig \
      meson setup build9g -Dtestmode=true
  meson compile -C build9g
  meson test    -C build9g
  ```

  Single test file: `TESTFLAGS='-file credentials.test' meson test -C build9g`.
  Release build with `/opt/tcl9`: `CC=gcc-14 PKG_CONFIG_PATH=/opt/tcl9/lib/pkgconfig
  meson setup build9 --buildtype=release -Dtestmode=true`.
  `build86` can't build the package without the dev-runtime packages
  (rl_http / rl_json / tomcrypt / reuri) installed for system Tcl 8.6.

- Build outputs land in `$builddir/tm/aws-VER.tm` + `$builddir/tm/aws/*.tm`.
  The test runner prepends the build dir to `tcl::tm::path` and calls
  `package forget aws aws::*` once (tcltest scans the tm path when
  first loaded — before our `-load` script runs — so the stale system
  ifneeded entries need to be dropped explicitly). See
  `tools/runtests.tcl`.

- `meson install` puts the package into `$(tcl.pc libdir)/tcl<MAJOR>/site-tcl/`
  — single install (2.8 MB), not the double install of the old
  Makefile. Docs land in `<prefix>/share/doc/aws/` and
  `<prefix>/share/man/mann/`. `DESTDIR=/stage meson install -C build9g`
  works for packagers.

- Doc source: `doc/aws.md.in` → pandoc → `aws.n`, `aws.html`, `README.md`.
  Alias target: `meson compile -C build9g doc`. README.md in the repo
  root is the rendered GFM output — update by copying
  `build9g/doc/README.md` over it when the source changes.

- Subproject fallback: if a dep isn't installed at the pkg-config
  prefix, meson falls back to building it from `subprojects/<name>.wrap`
  (git clones from GitHub). Build deps (`rl_json`, `parse_args`,
  `chantricks`, `brotli`) are required for `meson compile`; test deps
  (`rl_http`, `tomcrypt`, `reuri`, `s2n`, `tdom`) are gated by
  `-Dbuild_tests` (default on). Two deps still need meson support
  added upstream: `tdom` (~several thousand lines of autoconf — a
  dedicated session) and (to a lesser extent) `rl_http` + `chantricks`
  which currently get their meson.build injected via
  `subprojects/packagefiles/<name>/meson.build` patch dirs until the
  upstream releases catch up.

- Subproject installs: meson runs subproject install rules when
  `meson install` runs. Users who only want aws-tcl installed (relying
  on system-provided deps at runtime) should pass
  `meson install --skip-subprojects`. There is intentionally no
  `-Dinstall_deps` option — it can't be implemented cleanly without
  modifying each subproject's teabase to guard its install flag on a
  shared variable.

- Cross-package pkg-config / meson convention (in flight): every Tcl
  extension's `<name>.pc.in` exposes one of two variables:
  - **`tcl_pkg_path`** — directory to add to `auto_path` so
    `package require <name>` resolves a traditional pkgIndex.tcl-based
    package. Used by C extensions: rl_json, parse_args, brotli,
    tomcrypt, reuri, s2n, tdom.
  - **`tcl_tm_path`** — directory to add to `tcl::tm::path` for a
    .tm module. Used by pure-Tcl: chantricks, rl_http.

  Each package's meson.build also calls
  `meson.override_dependency(name, declare_dependency(variables: {...}))`
  with the same variables, so meson subproject consumers get the same
  interface as system installs. Goal: a single
  `dependency(name, fallback: [name, name_dep]).get_variable('tcl_pkg_path')`
  call works whether the dep was system-resolved or built from source.

  Status as of this session: pkg-config + override_dependency added to
  rl_json, reuri, tdom, parse_args, brotli, tomcrypt, s2n, chantricks,
  rl_http — but not yet released. aws-tcl's resolver is hybrid:
  prefers the new variables when present, falls back to the legacy
  top-level subproject variables (`pkg_so` / `tm_dir`) otherwise. As
  upstreams release tags that include the new bits, the wraps can
  point at those tags and the legacy fallback path becomes dead code
  (one day the resolver collapses to a single uniform call per dep).
  External consumers can already use
  `pkg-config --variable=tcl_pkg_path rl_json` against
  freshly-installed packages.

- This project's meson setup is the pure-Tcl pathfinder. Notable
  decisions (for when other pure-Tcl packages migrate):
  - Root `meson.build` doesn't invoke teabase; teabase assumes C
    sources and pulls in stubs / tommath / shim detection we don't
    need. A minimal inline config does the Tcl version detection and
    tclsh validation teabase would do.
  - `tclsh -c <script>` is not a thing; tclsh treats `-c` as a
    filename. Use a small tool script (`tools/print_patchlevel.tcl`)
    for configure-time Tcl evaluation via `run_command`.
  - tcltest's `-load` script evaluates *after* tcltest's initial tm
    scan — prepending to `tcl::tm::path` there doesn't re-resolve
    already-registered `package ifneeded` entries. `package forget`
    the package-under-test once (guarded by a
    `::_awstcl_path_primed` sentinel so we don't re-source the aws.tcl
    singletons on every test file's `loadTestedCommands`).
  - `install_dir` from `tcl_dep.get_variable('libdir')` lands in the
    Tcl-visible `lib/tclN/site-tcl` rather than Debian's multiarch
    `lib/x86_64-linux-gnu/tclN/site-tcl`.
  - 400+ generated per-service .tm files aren't listed as
    `custom_target` outputs; a post-install script
    (`tools/install_tm.tcl`) copies the whole tree at install time,
    honoring `DESTDIR` manually.
  - .tm output files live under `$builddir/tm/` (via `subdir('tm')`)
    rather than `$builddir/` directly, so the build root doesn't
    need to be on `tcl::tm::path` — Tcl refuses adds that are
    ancestors or descendants of an already-registered tm::path
    entry, which would collide with `$builddir/subprojects/<name>`
    entries for pure-Tcl subprojects.
  - Pure-Tcl subprojects expose `tm_dir` as both a top-level meson
    variable (for `subproject(name).get_variable('tm_dir')`) AND as
    a variable on their `declare_dependency` (for the future
    `dependency(name, fallback: …).get_variable('tm_dir')` pattern,
    once all deps have .pc files for pkg-config fallback).
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

## Configuration / credential resolution

The runtime follows the AWS CLI's resolution rules. The supported
provider chain, env vars, and config-file keys are listed in
`README.md` under "Configuration and credential resolution" —
that's the canonical source for what's in scope. Scope summary:

- Implemented: env-var creds, web-identity (IRSA / Pod Identity),
  profile-based resolution with `credential_process`, AssumeRole
  chains (`role_arn` + `source_profile` / `credential_source`), SSO
  (modern `sso_session` + `[sso-session NAME]`, and legacy
  `sso_start_url` on the profile — reads the `aws sso login` token
  cache and uses `sso:GetRoleCredentials`, with refresh-token refresh
  via `sso-oidc:CreateToken`), static profile creds, container creds
  (RELATIVE_URI + FULL_URI with auth token), IMDSv2 (v1 fallback),
  `AWS_ENDPOINT_URL[_<SERVICE>]`, FIPS/dualstack/STS-regional endpoint
  knobs, retry_mode and max_attempts from profile.
- Deliberately not implemented: interactive SSO login (device-code
  flow) — users run `aws sso login` from the CLI; `mfa_serial` (no
  way for the SDK to prompt — raises `{AWS UNSUPPORTED}`);
  `AWS_DEFAULTS_MODE`.
- `AWS_CA_BUNDLE` is honored via `rl_http -cafile` (requires rl_http
  1.24+). See the wire-up in `::aws::helpers::_ca_bundle` and the
  single `_req` call site.

SSO provider lives in `aws.tcl` under the `_sso_*` helpers
(`_sso_creds_from_session`, `_sso_creds_from_legacy`,
`_sso_creds_common`, `_sso_token_cache_path`, `_sso_load_token`,
`_sso_refresh_token`, `_sso_write_token_cache`,
`_sso_get_role_credentials`). Both sso-oidc and portal.sso calls are
made with direct rl_http (not through the operation dispatcher), since
those operations are `smithy.api#noAuth` and going through the
dispatcher would require a noAuth signing path we don't otherwise
need.

Helpers for config/credentials access live in `::aws::helpers`:
`_profile_name`, `_config_file_path`, `_credentials_file_path`,
`_config_profile_keys`, `_credentials_profile_keys`, `_profile_value`,
`_endpoint_url_override`, `_apply_endpoint_override`, `_config_bool`,
`_resolve_retry_config`. The per-thread override stack
`_cred_override` / `_with_creds` is used by the AssumeRole /
web-identity code paths to nest STS calls without recursing through
`get_creds`.

## Where the invariants live

- `tests/endpoint_rules.test` — 13882 cases from botocore; touches
  rule-engine changes break these loudly
- `tests/protocol_vectors.test` — 236 serialization cases from
  botocore; the best smoke for serialization work
- `tests/signing_vectors.test` — 74 SigV4 + SigV4-A test cases from
  AWS's aws-c-auth signing-test-suite; exercises canonical-request /
  STS / signature correctness including path normalization variants,
  UTF-8 paths, header continuation, duplicate keys, and pre-encoded
  query strings
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
(14374 / 14380 at time of writing; remaining skips are constraint-
gated: rl_aws_account + a handful of known-bug sentinels).

Requires rl_http ≥ 1.24 (for `-cafile` / `-cadir` / `-s2n_config`, the
keepalive-pool TLS-identity partitioning, plus the earlier 1.23
`-connect_timeout` / `-read_timeout` and reuri 0.15 compatibility)
and tomcrypt ≥ 0.9.2 (for `ecc_import_raw_private`, used by SigV4-A).
In a dev setup where a dependency isn't system-installed, point
make/tests at the dev build via
`AWSTCL_EXTRA_TM_PATH=/path/to/rl_http/tm:/path/to/tomcrypt/tm`.
