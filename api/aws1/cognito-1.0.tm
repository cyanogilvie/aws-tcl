# AWS Federated Identities API doc: https://docs.aws.amazon.com/cognitoidentity/latest/APIReference

package require aws 1.2
package require parse_args

namespace eval ::aws::cognito {
	namespace export *
	namespace ensemble create -prefixes no
	namespace path {
		::parse_args
	}

	proc req args { #<<<
		parse_args $args {
			-region		{-default us-east-1}
			-params		{-required}
			-action		{-required}
		}

		aws req POST cognito-identity / \
			-scheme			https \
			-region			$region \
			-body			[encoding convertto utf-8 $params] \
			-content_type	application/x-amz-json-1.1 \
			-headers		[list x-amz-target AWSCognitoIdentityService.$action]
	}

	#>>>
	foreach action {
		createIdentityPool
		deleteIdentities
		deleteIdentityPool
		describeIdentity
		describeIdentityPool
		getCredentialsForIdentity
		getId
		getIdentityPoolRoles
		getOpenIdToken
		getOpenIdTokenForDeveloperIdentity
		getPrincipalTagAttributeMap
		listIdentities
		listIdentityPools
		listTagsForResource
		lookupDeveloperIdentity
		mergeDeveloperIdentities
		setIdentityPoolRoles
		setPrincipalTagAttributeMap
		tagResource
		unlinkDeveloperIdentity
		unlinkIdentity
		untagResource
		updateIdentityPool
	} {
		proc $action args [string map \
			[list %action% [list [string totitle $action 0 0]] \
		] {
			parse_args $args {
				-region		{-default us-east-1}
				-params		{-required}
			}

			req -region $region -action %action% -params $params
		}]
	}
}

# vim: ft=tcl foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
