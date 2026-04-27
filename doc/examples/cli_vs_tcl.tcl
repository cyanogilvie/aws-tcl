package require aws
package require rl_json
namespace import ::rl_json::json

# aws sts get-caller-identity
set ident [aws sts get_caller_identity]
puts "account: [json get $ident Account]"

# aws s3api head-object --bucket assets --key foo/bar.jpg
set meta [aws s3 head_object -bucket assets -key foo/bar.jpg]
puts "size: [json get $meta ContentLength]"

# aws ec2 describe-instances \
#     --instance-ids    i-aaa i-bbb \
#     --filters         "Name=tag:Env,Values=prod"
set instances [aws ec2 describe_instances \
    -instance_ids   {i-aaa i-bbb} \
    -filters        [list [dict create Name tag:Env     Values prod]]]

# aws dynamodb put-item \
#     --table-name  Users \
#     --item        '{"pk":{"S":"user#42"},"count":{"N":"7"}}'
set pk      user#42
set count   7
set item [json template {
    {
        "pk":    { "S": "~S:pk"    },
        "count": { "N": "~S:count" }
    }
}]
aws dynamodb put_item -table_name Users -item $item

# aws lambda invoke --function-name worker --payload '{"op":"reindex"}' out.json
set resp [aws lambda invoke \
    -function_name  worker \
    -payload        [json template {{"op":"~S:op"}} {op reindex}]]
set fh [open out.json wb]
try {
    puts -nonewline $fh [json get $resp Payload]
} finally {
    close $fh
}
