# AWS ECR API doc: https://docs.aws.amazon.com/AmazonECR/latest/APIReference

package require aws 1.2

aws build_action_api -scheme https -service ecr -endpoint api.ecr -target_service AmazonEC2ContainerRegistry_V20150921 -actions {
	BatchCheckLayerAvailability
	BatchDeleteImage
	BatchGetImage
	CompleteLayerUpload
	CreateRepository
	DeleteLifecyclePolicy
	DeleteRegistryPolicy
	DeleteRepository
	DeleteRepositoryPolicy
	DescribeImages
	DescribeImageScanFindings
	DescribeRegistry
	DescribeRepositories
	GetAuthorizationToken
	GetDownloadUrlForLayer
	GetLifecyclePolicy
	GetLifecyclePolicyPreview
	GetRegistryPolicy
	GetRepositoryPolicy
	InitiateLayerUpload
	ListImages
	ListTagsForResource
	PutImage
	PutImageScanningConfiguration
	PutImageTagMutability
	PutLifecyclePolicy
	PutRegistryPolicy
	PutReplicationConfiguration
	SetRepositoryPolicy
	StartImageScan
	StartLifecyclePolicyPreview
	TagResource
	UntagResource
	UploadLayerPart
}

# vim: ft=tcl foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
