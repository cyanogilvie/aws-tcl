package require aws
package require rl_json
namespace import ::rl_json::json

# Service error codes are part of the Tcl errorCode, so you can pattern
# match on them with `try ... trap`. This is the preferred shape —
# catching by string match on the error message is brittle across
# service wording changes.
proc get_user user_id {
    try {
        aws dynamodb get_item \
            -table_name Users \
            -key        [json template {{"pk":{"S":"~S:user_id"}}}]
    } trap {AWS DYNAMODB Sender ResourceNotFoundException} {} {
        # Table doesn't exist. Different from "item not found" — an
        # empty Item in the response means the row is absent.
        throw {APP TABLE_MISSING} "Users table is not provisioned"
    } trap {AWS DYNAMODB Sender ProvisionedThroughputExceededException} {} {
        # The SDK already retried this per the configured retry policy;
        # if it still bubbles up the bucket is exhausted for real.
        throw {APP OVERLOADED} "DynamoDB throttling — try again shortly"
    }
}

# Catch all errors from a given service in one block. Tcl's trap
# pattern matching is prefix-based, so {AWS S3} matches any s3 error.
try {
    aws s3 put_object -bucket private -key secrets.txt -body $data
} trap {AWS S3} {msg opts} {
    log error "s3 upload failed: [dict get $opts -errorcode] $msg"
}

# Credential-resolution errors are distinct from service errors.
try {
    aws sts get_caller_identity
} trap {AWS SSO_TOKEN_EXPIRED} msg {
    puts stderr "Run 'aws sso login' to refresh your session."
    exit 1
} trap {AWS NO_CREDENTIALS} {} {
    puts stderr "No AWS credentials found in env, profile, or metadata."
    exit 1
}
