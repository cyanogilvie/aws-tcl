# Pagination (planned, not yet implemented)

AWS list/describe ops commonly return partial results with a
continuation token. Callers typically want one of three ergonomics:

1. **Iterate pages explicitly** (the current pattern — caller loops on
   `NextToken` / `NextMarker` / `Marker`).
2. **Auto-paginate** — the call returns the concatenation of all
   pages' result arrays.
3. **Lazy iterator** — a coroutine-style interface yielding one
   page-worth of results at a time.

This page captures what we know so implementing any of these is
straightforward.

## botocore's paginator spec

Each service has a `paginators-1.json` sibling of `service-2.json`:

```
botocore/botocore/data/<service>/<version>/paginators-1.json
```

Structure:

```json
{
    "pagination": {
        "ListStacks": {
            "input_token":  "NextToken",
            "output_token": "NextToken",
            "limit_key":    "MaxResults",
            "result_key":   "StackSummaries"
        },
        "DescribeStackEvents": {
            "input_token":  "NextToken",
            "output_token": "NextToken",
            "result_key":   "StackEvents"
        }
    }
}
```

Key fields:

- `input_token` (string or list of strings): the request param(s) the
  caller sets to resume. Multiple tokens appear in e.g. dynamodb where
  `ExclusiveStartTableName` goes with `LastEvaluatedTableName`.
- `output_token` (string or list): the field(s) in the response that
  carry the next continuation token. Same cardinality as input_token.
- `result_key` (string or list): output field(s) containing the
  paginated results. May be multiple (e.g. s3 list_objects_v2 has
  `Contents` and `CommonPrefixes`).
- `limit_key` (optional): the request param for page size (e.g.
  `MaxResults`, `MaxKeys`, `Limit`).
- `more_results` (optional): a boolean response field indicating "more
  pages available", used when there's no natural continuation token
  but e.g. `IsTruncated`.
- `non_aggregate_keys` (optional): output fields that aren't part of
  the result but should be surfaced per-page (metadata).

See the botocore pagination docs at
<https://boto3.amazonaws.com/v1/documentation/api/latest/guide/paginators.html>
for deeper semantics.

## Implementation sketch

### Build-time wiring

In `build.tcl`, alongside `compile_endpoint_rules`, read
`paginators-1.json` for each service and attach the parsed spec to the
service module:

```tcl
set pag_fn [file join $definitions $service_dir $latest paginators-1.json]
if {[file exists $pag_fn]} {
    set paginators [json extract [readfile $pag_fn] pagination]
    append service_code "variable paginators $paginators" \n
}
```

For each op with a paginator entry, the generator emits a
`<op_name>_pages` proc (or `<op_name>_paginate` — name tbd) that
wraps the existing per-op proc.

### Runtime wrapper shape

Option A (auto-paginate, concat results):

```tcl
proc list_stacks_pages args {
    variable paginators
    set spec [json extract $paginators ListStacks]
    set input_token  [json get $spec input_token]
    set output_token [json get $spec output_token]
    set result_key   [json get $spec result_key]

    set all_results  {[]}
    set token        ""
    while 1 {
        set page_args $args
        if {$token ne ""} {lappend page_args -[aws::from_camel $input_token] $token}
        set resp [list_stacks {*}$page_args]
        # Append this page's results to the aggregate.
        if {[json exists $resp $result_key]} {
            json foreach entry [json extract $resp $result_key] {
                json set all_results end+1 [json extract $entry]
            }
        }
        if {![json exists $resp $output_token]} break
        set token [json get $resp $output_token]
        if {$token eq "" || $token eq "null"} break
    }
    json template {
        { "~K:result_key": "~J:all_results" }
    }
}
```

Option B (yield-per-page): use Tcl 8.6+ coroutines.

Option C (explicit token exposed, just a helper to check): minimal —
just return the response unchanged and document the pattern.

### Multi-key handling

For paginators with list-valued tokens (dynamodb), the spec gives
parallel lists and the wrapper has to zip them.

### Backwards compatibility

The original per-op proc (`list_stacks`) should stay exactly as-is
(non-paginating single call). Paginated convenience goes to a sibling
proc or takes an opt-in flag.

## Decision points

- Proc naming: `list_stacks_pages` / `list_stacks_paginate` /
  `-paginate 1` flag on `list_stacks`? Pick one convention and document
  it. A flag keeps the API surface smaller but complicates return
  types (same proc returns different structures with/without the
  flag). A suffix is clearer.
- Concat all vs. yield: a lot of services have potentially huge result
  sets (s3 buckets with millions of keys, cloudwatch metrics). A
  concat-everything implementation is ergonomic for small sets and
  dangerous for large ones. Yielding per page via a coroutine is
  probably the best default.
- Stopping condition: when does a paginator stop? Most services use
  an empty/missing output_token. Some (s3) use `IsTruncated: false`
  (`more_results` field). Handle both.

## Test approach

Botocore has pagination test fixtures at
`botocore/tests/unit/data/paginators/` but those test botocore's own
paginator class. Smithy tests at
`botocore/tests/unit/protocols/*.json` don't cover pagination.

Best approach: add `pagination.test` with integration tests against
the `rl_aws_account` constraint for services that reliably return
more than one page of results (cloudformation stacks, iam policies,
lambda functions).

## Useful references

- botocore pagination guide:
  <https://boto3.amazonaws.com/v1/documentation/api/latest/guide/paginators.html>
- Per-service paginators-1.json files: every service dir in
  `botocore/botocore/data/`
- botocore's paginator implementation:
  `botocore/botocore/paginate.py` (python reference)
