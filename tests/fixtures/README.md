# Test fixture stack

A CloudFormation stack that provides deterministic AWS resources for the
live portion of the test suite. Run the tests in your own AWS account by
deploying the stack, seeding a few S3 objects, running tests, then tearing it
down when you're done.

## What's in the stack

All resources are free-tier eligible. Names are derived from the stack name so
multiple parallel stacks (e.g. in different regions) won't collide.

| Resource              | Count | Purpose                                                     |
| --------------------- | ----- | ----------------------------------------------------------- |
| `AWS::S3::Bucket`      | 1    | Populated by `make seed-fixtures` with keys that exercise sigv4 encoding (spaces, UTF-8, reserved chars) and give a mix of Objects + CommonPrefixes when listed with `-delimiter /`. |
| `AWS::IAM::ManagedPolicy` | 12 | Paginated `list_policies -scope Local` coverage. Policies grant `s3:GetObject` on `*` — inert, not attached to anything. |
| `AWS::SSM::Parameter`  | 12   | Paginated `describe_parameters` coverage under a common prefix. |
| `AWS::Logs::LogGroup`  | 3    | `describe_log_groups` coverage with prefix filter, 1-day retention. |

Stack outputs (read by `tests/fixtures.tcl`):

- `BucketName` — the globally-unique S3 bucket name
- `PolicyPrefix` — e.g. `aws-tcl-test-policy-`
- `ParamPrefix` — e.g. `/aws-tcl-test/`
- `LogGroupPrefix` — e.g. `/aws/aws-tcl-test/`
- `StackName` — useful for scoping assertions in tests

## Deploy

```sh
make deploy-fixtures        # creates/updates the stack
make seed-fixtures          # puts the S3 test objects
# -- or in one step --
make fixtures
```

Override stack name or region via environment:

```sh
AWS_TCL_TEST_STACK=my-aws-tcl-test AWS_REGION=eu-west-1 make fixtures
```

The tests read the same env vars via `tests/fixtures.tcl`.

## Run the live tests

```sh
make test TESTFLAGS='-file pagination.test'
```

Tests gated by the `aws_tcl_fixtures` constraint skip cleanly if the stack
isn't deployed (or credentials aren't available).

## Teardown

```sh
make teardown-fixtures
```

This empties the bucket (CloudFormation can't delete a non-empty bucket) and
then calls `delete-stack` + waits for completion.

## Required IAM permissions

The identity running `make fixtures` needs:

- `cloudformation:CreateStack` / `UpdateStack` / `DeleteStack` / `DescribeStacks`
- `iam:CreateRole` (for the stack's rollback role, if not using service role)
- `iam:CreatePolicy` / `DeletePolicy` / `GetPolicy` / `ListPolicies`
- `s3:CreateBucket` / `DeleteBucket` / `PutBucketPolicy` / `PutBucketPublicAccessBlock`
- `s3:PutObject` / `GetObject` / `DeleteObject` / `ListBucket` / `DeleteObjects`
- `ssm:PutParameter` / `DeleteParameter` / `GetParameter`
- `logs:CreateLogGroup` / `DeleteLogGroup` / `PutRetentionPolicy` / `DescribeLogGroups`

(The running test suite itself only needs read permissions on these resources.)

## Regenerating the template

`aws-tcl-test.json` is hand-edited. If you want to bump resource counts,
`_gen_template.tcl` is a small rl_json-based generator that produced the
initial version:

```sh
tclsh9.0 tests/fixtures/_gen_template.tcl > tests/fixtures/aws-tcl-test.json
```

Adjust the `for {set i 1} {$i <= N}` loops at the bottom to change counts.
