# AWS Federated Identities API doc: https://docs.aws.amazon.com/cognitoidentity/latest/APIReference

package require aws 1.2

aws build_action_api -scheme https -service cognito-identity -target_service AWSCognitoIdentityService -actions {
	CreateIdentityPool
	DeleteIdentities
	DeleteIdentityPool
	DescribeIdentity
	DescribeIdentityPool
	GetCredentialsForIdentity
	GetId
	GetIdentityPoolRoles
	GetOpenIdToken
	GetOpenIdTokenForDeveloperIdentity
	GetPrincipalTagAttributeMap
	ListIdentities
	ListIdentityPools
	ListTagsForResource
	LookupDeveloperIdentity
	MergeDeveloperIdentities
	SetIdentityPoolRoles
	SetPrincipalTagAttributeMap
	TagResource
	UnlinkDeveloperIdentity
	UnlinkIdentity
	UntagResource
	UpdateIdentityPool
}

# vim: ft=tcl foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
