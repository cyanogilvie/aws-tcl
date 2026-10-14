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
    } trap AWS {msg opts} {
        # DynamoDB reports namespace-qualified codes
        # (com.amazonaws.dynamodb.v20120810#ResourceNotFoundException),
        # which trap's prefix matching can't glob, so match on the
        # unqualified tail of the code here.
        set code [lindex [dict get $opts -errorcode] 1]
        switch -- [lindex [split $code #] end] {
            ResourceNotFoundException {
                # Table doesn't exist. Different from "item not found" —
                # an empty Item in the response means the row is absent.
                throw {APP TABLE_MISSING} "Users table is not provisioned"
            }
            ProvisionedThroughputExceededException {
                throw {APP OVERLOADED} "DynamoDB throttling — try again shortly"
            }
        }
        return -options $opts $msg
    }
}

# S3 errors carry the request id, resource and every field of the XML
# error element in the errorCode: {AWS Code RequestId Resource Details}
try {
    aws s3 put_object -bucket private -key secrets.txt -body $data
} trap {AWS AccessDenied} {msg opts} {
    lassign [dict get $opts -errorcode] - code requestid resource details
    log error "s3 upload to $resource denied (request $requestid): $msg"
} trap AWS {msg opts} {
    # Tcl's trap pattern matching is prefix-based, so {AWS} matches any
    # AWS-side error.
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
