# Pagination

`aws foreach` and `aws lmap` drive AWS list/describe operations page-by-page,
streaming results one item at a time. Both are routed through the `::aws`
ensemble's `-unknown` handler (not `-map`, because `-map` disables auto-resolve
of exported procs — see `aws.tcl:14-26`), which re-dispatches to the private
`::aws::_foreach` / `::aws::_lmap` implementations. Naming them `_foreach`
/ `_lmap` inside the namespace avoids shadowing the builtins for any
namespace-scoped code.

## Caller surface

```tcl
aws foreach <itemvar> ?-itemtype <var>? ?-page <var>? ?-type <itemtype>?
    ?-result_key <key>? ?-page_size <N>? <svc> <op> ?opts...? <body>

aws lmap <itemvar> ... <body>      ;# collects body's return value per iter
```

- `<itemvar>` — single item bound per iteration; always a JSON fragment.
- `-itemtype <var>` — binds the current item's shape name (`Object`,
  `CommonPrefix`, `UserDetail` …). Required when the paginator has multiple
  result containers unless `-type` or `-result_key` is given.
- `-page <var>` — binds the full current page JSON once per page; the body is
  responsible for `unset`ing it if it wants an `info exists` signal on the
  next page. Aliased — harmless no-op if the option isn't supplied.
- `-type <itemtype>` — filter: only iterate items of this shape. Also
  satisfies the multi-container disambiguation.
- `-result_key <key>` — pin to one result container (matches dotted path or
  tail segment). Also disambiguates.
- `-page_size <N>` — forwarded as the op's `limit_key` arg (e.g.
  `-max_items 25`). Errors with `NO_LIMIT_KEY` if the paginator spec has none.
- Body control flow: `break` exits `aws foreach` (lmap returns partial list);
  `continue` next item; `return` returns from caller's proc; error
  propagates. `throw {AWS FOREACH NEXT_PAGE} {}` stops processing the current
  page and fetches the next one.

## The paginator-metadata variable

Each service module gets a `variable paginators` dict keyed by PascalCase op
name (matching paginators-1.json native form — dispatcher does `to_camel` on
the caller's snake command name). Per-op metadata shape:

```tcl
{
    input_tokens        <list of request-field names>
    output_tokens       <list, parallel to input_tokens>
    limit_key           <field or "">
    more_results        <field or "">
    non_aggregate_keys  <list>
    item_containers     <list of {itemtype {pathseg ...}}>
}
```

- `input_tokens` / `output_tokens` are always lists (length 1 for the common
  case; 3 for route53 ListResourceRecordSets; 2 for s3
  ListMultipartUploads / ListObjectVersions).
- `item_containers` pairs the member-shape name (for `-itemtype`) with the
  dot-split path into the response (for `json extract`). Built from a
  shape-tree walk at build time.

## Build-time compilation

`aws::build::compile_paginators` in `build.tcl`:

1. Loads `paginators-1.json` if present.
2. For each op, resolves each `result_key` by walking the output shape's
   `members[seg].shape.members[seg]....` chain.
3. Drops entries whose terminal shape isn't `type: list` — this kills
   Category-3 scalar leaks (`dynamodb Query` declares `[Items, Count,
   ScannedCount]` as result_keys; Count/ScannedCount are integers and
   disappear, leaving `Items` as the only container).
4. Records the list's `member.shape` as the item type.
5. Ops that end up with zero list-valued containers are dropped entirely.
6. Normalises `input_token` / `output_token` strings to single-element lists.

Emitted into the service module as `variable paginators $dict`. Both
non-rest-xml and rest-xml branches of `build_aws_services` inject it.

## Runtime orchestration (`aws.tcl:_foreach`)

1. `package require aws::$svc`; look up `::aws::${svc}::paginators`; error
   NOT_PAGINATED if missing or op isn't in the dict.
2. Parse args; validate (TYPE_REQUIRED for multi-container ambiguity;
   NO_SUCH_KEY if `-result_key` doesn't match; NO_LIMIT_KEY for `-page_size`
   on ops with no `limit_key`; NO_BODY for missing body script).
3. Loop: invoke `aws::$svc $command ...svcargs ...page_size_args
   ...next_page_args` via `uplevel 1`. Each invocation runs in the caller's
   frame so arg-name rewriting and endpoint resolution behave exactly as a
   direct call.
4. Set caller's `-page` var to the whole response.
5. For each `item_container`, filter by `-type`, set `-itemtype` var if
   requested, iterate `rl_json::json foreach` over the extracted list,
   uplevel-eval the body per item.
6. Body return codes: `break` → exit loop (returns `$reslist`);
   `continue` → next item; `return` → propagate with `-level` bumped;
   `NEXT_PAGE` trap → set `$breakout`, break inner and outer loops to fetch
   the next page; error → propagate; ok with `-collecting` → lappend to
   `$reslist`.
7. Termination: `more_results` present and false → stop; otherwise extract
   any non-empty `output_token` values and thread them back into
   `next_page_args` (`-[from_camel $in_name] $tok`). No tokens found → stop.

Order of `try ... on` handlers matters: `trap {AWS FOREACH NEXT_PAGE}` must
come before `on error`, else the general error handler swallows it.

## Response-key name conventions

Paginator paths use the shape member names (which also appear verbatim in the
wire response for JSON protocols, and in the JSON produced by
`_handle_xml_resp` for XML protocols). No `locationName` translation is
needed at pagination time — the response has already been normalised.

## Compound-token ops

Only 3 ops use parallel token arrays:

- `s3 ListMultipartUploads` — `{KeyMarker UploadIdMarker}` /
  `{NextKeyMarker NextUploadIdMarker}`
- `s3 ListObjectVersions` — `{KeyMarker VersionIdMarker}` /
  `{NextKeyMarker NextVersionIdMarker}`
- `route53 ListResourceRecordSets` —
  `{StartRecordName StartRecordType StartRecordIdentifier}` /
  `{NextRecordName NextRecordType NextRecordIdentifier}`

The dispatcher zips the pair — any non-empty output_token value gets
forwarded as its paired input. `foreach in out ...` walks parallel arrays of
equal length.

## Multi-container ops (the 32 "Category 1" set)

Ops with multiple list result_keys fall into:

- **Heterogeneous** (~15 ops) — different item shapes, caller may legitimately
  want all of them. Disambiguate with `-itemtype`. Examples:
  `iam GetAccountAuthorizationDetails` (User/Group/Role/ManagedPolicyDetail),
  `cloudwatch DescribeAlarms` (MetricAlarm/CompositeAlarm),
  `s3 ListObjectsV2` (Object/CommonPrefix),
  `devops-guru ListInsights` (ProactiveInsight/ReactiveInsight).
- **Parallel/redundant** (~8 ops) — same entities, two views; caller wants
  one. Pin with `-result_key`. Examples:
  `ec2 DescribeVpcEndpointServices` (ServiceNames/ServiceDetails),
  `resource-groups ListGroups` (GroupIdentifiers/Groups).
- **Scalar leaks** (already filtered at build time — none reach runtime).
- **Items + diagnostic list** (~3 ops) — e.g. `logs FilterLogEvents` has
  `events` plus `searchedLogStreams` (diagnostic). Caller either switches in
  the body or pins `-result_key events`.

The build-time shape walk picks the member-shape name as `-itemtype`, so
`{CommonPrefix {CommonPrefixes}}` reads naturally in a `switch` (rather than
the list-name `CommonPrefixes`).

## `non_aggregate_keys`

Not used by the dispatcher directly — the caller extracts these from
`-page` when it wants them. About 76 ops across 25 services populate this
(e.g. `dynamodb Query`'s `ConsumedCapacity`, `connect Search*`'s
`ApproximateTotalCount`, `cloudformation DescribeChangeSet`'s 20+ metadata
fields). Kept in the metadata for completeness and in case a later
convenience wrapper wants it.

## Testing

`tests/pagination.test`:

- A fake-service harness (`::aws::fake`) registers per-op paginator metadata
  and a canned page sequence, then stubs op procs that return pages in order
  and record every call. Lets us test every knob without live AWS.
- 23 unit tests covering: single-container iteration, token threading,
  break/continue/return/error propagation, `NEXT_PAGE` throw, lmap collection,
  lmap partial-result on break, `-page` set-once semantics, `-page_size`
  mapping and NO_LIMIT_KEY error, multi-container disambiguation errors and
  all three workarounds (`-itemtype`, `-type`, `-result_key`), compound
  tokens, `more_results` flag early termination.
- 4 live integration tests gated by `rl_aws_account`: lambda list_functions
  spanning pages, cloudformation list_stacks, iam list_policies with
  `-page_size`, s3 list_objects_v2 multi-container with `-itemtype`.

## References

- Implementation: `aws.tcl` `_foreach` (~line 3070) and `_lmap` (below it);
  ensemble wiring at `aws.tcl:14`.
- Build-time: `build.tcl` `compile_paginators` (and `_normalize_token_list`);
  injection points in both service-generation loops.
- Tests: `tests/pagination.test`.
- botocore pagination guide:
  <https://boto3.amazonaws.com/v1/documentation/api/latest/guide/paginators.html>
- Spec files: `botocore/botocore/data/<service>/<version>/paginators-1.json`.
