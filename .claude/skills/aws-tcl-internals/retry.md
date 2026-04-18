# Retry, backoff, and rate-limiting

## Where it lives

- `aws.tcl` — `::aws::helpers` holds the whole retry machinery. Key bits:
  - `_aws_req` — the retry loop (wraps `_req`).
  - `_classify_error` — maps a caught `options` dict to one of
    `throttle|transient|clockskew|none`.
  - `_backoff_ms attempt` — full-jitter exponential backoff, ms.
  - `_retry_after_ms headers` — honors `Retry-After` header, ms.
  - `_sleep_ms ms` — sleep without re-entering the event loop. In a
    coroutine: `after $ms [info coroutine] ; yield` (plus a delete
    trace to cancel the `after` if the coroutine is torn down). In
    plain script context: `thread::cond wait $cond $mutex $ms` on a
    per-thread mutex+cond — blocks the thread entirely, no `vwait`,
    no nested event dispatching. (This explicitly avoids the classic
    nested-vwait hazard: events servicing the sleep can't recursively
    trigger another AWS call with its own sleep.)
  - `_rate_before_send key` / `_rate_after_throttle key` — per-service
    send pacing state, stored in a tsv array so the state is
    process-scoped (matching `rl_http`'s keepalive pool).
  - `_uuid4` — tomcrypt-backed RFC 4122 v4.
- `aws.tcl` — `::aws::_auto_idempotency_token var` fills a variable
  with a UUIDv4 if the caller did not supply one.
- `build.tcl` — the main op-compilation loop (json / rest-json / query
  / ec2) emits an `_auto_idempotency_token $argname` static line for
  every top-level input-shape member with `idempotencyToken: true`.
- `aws.tcl` — `_compile_rest-xml_op` does the equivalent for rest-xml
  by injecting a `dict set params $member [_uuid4]` line after
  `parse_args`.

## What gets retried

`_classify_error` uses three tables defined in `::aws::helpers`:

- `_throttle_codes`: the full union of throttle-class error codes seen
  across services — Throttling / ThrottlingException / ThrottledException
  / RequestThrottled(Exception) / TooManyRequestsException /
  ProvisionedThroughputExceededException /
  TransactionInProgressException / RequestLimitExceeded /
  BandwidthLimitExceeded / LimitExceededException / SlowDown /
  PriorRequestNotComplete / EC2ThrottledException.
- `_transient_codes`: InternalError / InternalFailure /
  InternalServerError / InternalServerException / ServiceUnavailable /
  BadGateway / GatewayTimeout / RequestTimeout / RequestTimeoutException
  / IDPCommunicationError / RequestTimeTooSkewed (currently classified
  as `clockskew` and handled on the transient path).
- `_retry_statuses`: 408 / 425 / 429 / 500 / 502 / 503 / 504 / 509 —
  used when the server response had no parseable body and `_aws_error`
  falls back to `throw [list AWS <http-code>]`. 429 is treated as
  throttle, the rest as transient.

Non-`AWS` errorcodes (socket / DNS / TLS errors from `rl_http`) are
classified as transient and retried.

`ValidationException`, `AccessDenied`, signing errors, and anything
not in those tables return `none` and propagate to the caller immediately.

## Backoff

Full-jitter exponential per the AWS SDK "standard" retry mode:

```
delay = rand(0, 1) * min(base * 2^(attempt-1), cap)
```

Defaults: `_backoff_base = 0.5s`, `_backoff_cap = 20s`. `attempt` is
1-based, so the first retry sleeps in [0, 0.5s], then [0, 1s], [0, 2s],
[0, 4s], up to the 20s cap.

If the response carries a usable `Retry-After` header
(either integer seconds or an HTTP-date), that delay wins over the
exponential backoff calculation.

## Rate limit

`_rate_before_send` / `_rate_after_throttle` maintain per-service
token-bucket-ish state in `tsv::set aws_tcl_rate <key>`. The key is
`[_rate_key $sig_service $region]` → `"<service>:<region>"`. State is
a three-list `{max_rate next_send last_throttle}`:

- `max_rate` — Hz cap for send spacing. Starts at `_max_send_rate` (50),
  floor at `_min_send_rate` (0.5).
- `next_send` — earliest clock microseconds we're allowed to send.
- `last_throttle` — clock seconds of the last observed throttle.

Before each send: read the current max_rate, optionally grow it (back
toward 50 Hz) if more than 10 s have passed since the last throttle,
then schedule `next_send = max(now, prev_next_send) + 1e6/max_rate`
and sleep if `wait_us > 0`.

On a throttle response: halve `max_rate` (floor 0.5 Hz), stamp
`last_throttle = now`.

In `retry_mode = legacy`, pacing is skipped entirely — this matches
what pre-2026 aws-tcl did except that retries now use exponential
backoff regardless of mode.

## Why tsv for rate state

`rl_http` parks keepalive connections in a process-scoped tsv pool
(`rl_http.tcl` `_keepalive_park` + the background sweeper thread at
~lines 156-202). A connection that served a DynamoDB request in thread
A can be pulled by thread B's next request. If the rate-limit state
were only in A's namespace variables, B would send at full rate into
the still-throttled endpoint. Keeping the state in `tsv` gives it the
same lifetime and scope as the underlying sockets.

`Thread` is already a hard dependency of `rl_http`, so we don't need a
single-threaded fallback.

## Idempotency tokens

For ops where the input shape has a top-level member marked
`idempotencyToken: true` (e.g. ec2 `RunInstances` `ClientToken`,
eks `CreateCluster` `clientRequestToken`), the generated code
auto-populates a UUIDv4 when the caller omits the arg. This means an
internal retry after a transient error — including a network
disconnect mid-request — is deduped by the service: it'll return the
same response instead of creating a duplicate resource.

If the caller supplies the token, it's used verbatim.

Ops whose idempotency token lives inside a nested structure (very
rare; not seen in botocore) are not auto-populated.

## Knobs

- `AWS_RETRY_MODE` env var → `::aws::helpers::retry_mode`
  (`standard` default, `legacy` to skip pacing, `adaptive` reserved).
- `AWS_MAX_ATTEMPTS` env var → `::aws::helpers::max_attempts`
  (default 3; applies when the caller doesn't pass `-retries`).
- `AWSTCL_REQUEST_TIMEOUT` env var → `::aws::helpers::request_timeout`
  (default 60s; rl_http's `-timeout` — overall per-request budget
  from start to completion; primary thread-exhaustion ceiling).
- `AWSTCL_CONNECT_TIMEOUT` → `::aws::helpers::connect_timeout` (default
  5s; rl_http's `-connect_timeout` — cap on the DNS+TCP+TLS phase).
- `AWSTCL_READ_TIMEOUT` → `::aws::helpers::read_timeout` (default 30s;
  rl_http's `-read_timeout` — cap on each inter-readable-chunk wait,
  effectively "max silent gap between bytes"; resets per chunk).

  Connect and read timeouts can only *shorten*, never extend, the
  overall request budget. Streaming-style calls (Lambda invoke with
  response streaming, long-running S3 uploads) should raise
  `-timeout` while leaving `-read_timeout` tight, e.g.
  `-timeout 900 -read_timeout 30`.

  All three configs are overridable per-call via `-timeout N`,
  `-connect_timeout N`, `-read_timeout N` on any generated op.
- `AWSTCL_MAX_KEEPALIVE_AGE` env var → `::aws::helpers::max_keepalive_age`
  (default 60s; caps how long a pooled keepalive connection may live
  before being reconnected — the Java SDK v2 `connectionMaxIdleTime`
  analog). Matters for S3 / DynamoDB, which scale via new partitions
  and fronting IPs: a stubbornly reused connection sticks to stale
  capacity. Per-call override via `-max_keepalive_age N`;
  `-max_keepalive_count N` caps reuses per connection.
- Per-call: still-accepted `-retries N` on `_aws_req`.
- Shorten backoff in tests: set `::aws::helpers::_backoff_base` and
  `::aws::helpers::_backoff_cap` to small values.

All three transport options (`-timeout`, `-max_keepalive_age`,
`-max_keepalive_count`) are accepted by every generated op
automatically via the `%p` template in `_reconstruct` (for
json/rest-json/query/ec2) and via the argspec extension in
`_compile_rest-xml_op` (for rest-xml). They flow through
op → `_service_req` → `_aws_req` → `_req` → `rl_http`.

## Testing

- `tests/units.test` — classifier tables, `_backoff_ms` bounds,
  `_retry_after_ms` parsing, `_uuid4` format + uniqueness,
  `_auto_idempotency_token` behavior, presence of injection in
  generated op bodies.
- `tests/retry.test` — end-to-end retry loop with a programmable
  mock `_req` (scripted sequences of successes, AWS errors, and
  non-AWS errorcodes). Covers all throttle codes, transient codes,
  socket errors, non-retryable errors, exhaustion, and `Retry-After`.

## Not yet implemented

- Cubic rate adjustor / full adaptive mode (the simpler halve-and-recover
  model covers the common case).
- Retry quota / cross-call token bucket (would cap aggregate retry
  volume under sustained failure).
- Clock-skew resync: `RequestTimeTooSkewed` is classified as
  `clockskew` but treated the same as transient. A proper impl
  would parse the server's date header and adjust a signing-time
  offset.
- Per-service retry config overrides from botocore's `_retry.json`
  (we use the union of all throttling/transient codes globally, which
  is harmless: the same codes mean the same thing across services).
- Active keepalive-pool flush on sustained throttle. When S3/DynamoDB
  scale out we'd benefit from dropping pooled connections to
  `<host>` + invalidating the resolve cache for that host (both in
  rl_http's tsv arrays) so the next request picks up a freshly
  resolved IP. The hooks are all present — `tsv::array rl_http_keepalive_chans`
  keyed by `scheme://host:port` and `tsv::array _rl_http_resolve_cache`
  keyed by host — it's just a matter of calling them from the throttle
  path for specific services. Deferred; current `-max_keepalive_age 60`
  default gets us most of the way.
