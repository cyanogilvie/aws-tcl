# AWS Secrets Manager API reference: https://docs.aws.amazon.com/secretsmanager/latest/apireference

package require aws

aws build_action_api -scheme https -service secretsmanager -actions {
	CancelRotateSecret
	CreateSecret
	DeleteResourcePolicy
	DeleteSecret
	DescribeSecret
	GetRandomPassword
	GetResourcePolicy
	GetSecretValue
	ListSecrets
	ListSecretVersionIds
	PutResourcePolicy
	PutSecretValue
	RemoveRegionsFromReplication
	ReplicateSecretToRegions
	RestoreSecret
	RotateSecret
	StopReplicationToReplica
	TagResource
	UntagResource
	UpdateSecret
	UpdateSecretVersionStage
	ValidateResourcePolicy
}

# vim: ft=tcl foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
