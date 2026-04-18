#!/usr/bin/env tclsh9.0
# Regenerate aws-tcl-test.json. Tweak the counts at the bottom of this file
# and re-run: `tclsh9.0 tests/fixtures/_gen_template.tcl > tests/fixtures/aws-tcl-test.json`
#
# Keeps the template rectangular (12 policies, 12 params, 3 log groups — adjust
# to taste) without hand-editing N copies of near-identical JSON.

package require rl_json

set tmpl [::rl_json::json template {
	{
		"AWSTemplateFormatVersion": "2010-09-09",
		"Description": "aws-tcl test fixtures -- deterministic state for the pagination / live-integration test suite. Free-tier resources only. Tear down with `make teardown-fixtures`.",
		"Resources": {
			"TestBucket": {
				"Type": "AWS::S3::Bucket",
				"DeletionPolicy": "Delete",
				"Properties": {
					"BucketName": { "Fn::Sub": "${AWS::StackName}-${AWS::AccountId}-${AWS::Region}" },
					"PublicAccessBlockConfiguration": {
						"BlockPublicAcls": true,
						"BlockPublicPolicy": true,
						"IgnorePublicAcls": true,
						"RestrictPublicBuckets": true
					}
				}
			}
		},
		"Outputs": {
			"BucketName":     { "Value": { "Ref": "TestBucket" } },
			"PolicyPrefix":   { "Value": { "Fn::Sub": "${AWS::StackName}-policy-" } },
			"ParamPrefix":    { "Value": { "Fn::Sub": "/fixtures/${AWS::StackName}/" } },
			"LogGroupPrefix": { "Value": { "Fn::Sub": "/fixtures/${AWS::StackName}/" } },
			"StackName":      { "Value": { "Ref": "AWS::StackName" } }
		}
	}
}]

proc policy_res n {
	set stack_tmpl "\${AWS::StackName}-policy-$n"
	::rl_json::json template [string map [list @stack $stack_tmpl @n $n] {
		{
			"Type": "AWS::IAM::ManagedPolicy",
			"Properties": {
				"ManagedPolicyName": { "Fn::Sub": "@stack" },
				"Description": "aws-tcl test fixture @n -- inert read-only stub for pagination tests",
				"PolicyDocument": {
					"Version": "2012-10-17",
					"Statement": [ { "Effect": "Allow", "Action": "s3:GetObject", "Resource": "*" } ]
				}
			}
		}
	}]
}

proc param_res n {
	# SSM rejects parameter names whose first hierarchy element starts with
	# "aws" or "ssm" with GeneralServiceException. Wrap under a neutral
	# /fixtures/ prefix to stay clear of that.
	set name_tmpl "/fixtures/\${AWS::StackName}/param-$n"
	::rl_json::json template [string map [list @name $name_tmpl @n $n] {
		{
			"Type": "AWS::SSM::Parameter",
			"Properties": {
				"Name":  { "Fn::Sub": "@name" },
				"Type":  "String",
				"Value": "@n"
			}
		}
	}]
}

proc loggroup_res n {
	# /aws/ prefix is conventionally reserved for AWS-managed log groups
	# (Lambda, API Gateway, etc.) — use the same neutral /fixtures/ prefix as
	# the SSM parameters for consistency.
	set name_tmpl "/fixtures/\${AWS::StackName}/group-$n"
	::rl_json::json template [string map [list @name $name_tmpl] {
		{
			"Type": "AWS::Logs::LogGroup",
			"DeletionPolicy": "Delete",
			"Properties": {
				"LogGroupName":    { "Fn::Sub": "@name" },
				"RetentionInDays": 1
			}
		}
	}]
}

for {set i 1} {$i <= 12} {incr i} {
	set n [format "%02d" $i]
	::rl_json::json set tmpl Resources "Policy$n" [policy_res $n]
	::rl_json::json set tmpl Resources "Param$n"  [param_res $n]
}
for {set i 1} {$i <= 3} {incr i} {
	set n [format "%02d" $i]
	::rl_json::json set tmpl Resources "LogGroup$n" [loggroup_res $n]
}

puts [::rl_json::json pretty $tmpl]
