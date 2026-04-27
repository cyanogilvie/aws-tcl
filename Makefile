# Residual Makefile — fixture-stack lifecycle only.
#
# Build, test, install, and doc targets moved to meson. Use:
#
#   PKG_CONFIG_PATH=/opt/tcl9g/lib/pkgconfig meson setup build9g -Dtestmode=true
#   meson compile -C build9g
#   meson test    -C build9g
#   meson install -C build9g --destdir /tmp/stage    # staged install
#
# The fixture stack (CloudFormation + S3 seed) is pure shell automation
# against the AWS CLI — there's no meaningful meson step to wrap, so
# these targets remain in make.

AWSTCL_TEST_STACK ?= aws-tcl-test
AWS_REGION        ?= us-east-1
AWS_CLI           ?= aws
BUILDDIR          ?= build9g
FIXTURE_TEMPLATE   = tests/fixtures/aws-tcl-test.json
TCLSH             ?= $(shell command -v tclsh 2>/dev/null)

deploy-fixtures:
	$(AWS_CLI) cloudformation deploy \
		--template-file $(FIXTURE_TEMPLATE) \
		--stack-name    $(AWSTCL_TEST_STACK) \
		--region        $(AWS_REGION) \
		--capabilities  CAPABILITY_NAMED_IAM \
		--disable-rollback

fixture-events:
	$(AWS_CLI) cloudformation describe-stack-events \
		--stack-name $(AWSTCL_TEST_STACK) \
		--region     $(AWS_REGION) \
		--query 'StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED`].[LogicalResourceId,ResourceType,ResourceStatusReason]' \
		--output table

seed-fixtures:
	AWSTCL_TEST_STACK=$(AWSTCL_TEST_STACK) AWS_REGION=$(AWS_REGION) \
		$(TCLSH) tests/fixtures/seed_objects.tcl

fixtures: deploy-fixtures seed-fixtures

empty-fixtures-bucket:
	AWSTCL_TEST_STACK=$(AWSTCL_TEST_STACK) AWS_REGION=$(AWS_REGION) \
		$(TCLSH) tests/fixtures/empty_bucket.tcl

teardown-fixtures: empty-fixtures-bucket
	$(AWS_CLI) cloudformation delete-stack \
		--stack-name $(AWSTCL_TEST_STACK) \
		--region     $(AWS_REGION)
	$(AWS_CLI) cloudformation wait stack-delete-complete \
		--stack-name $(AWSTCL_TEST_STACK) \
		--region     $(AWS_REGION)

fixture-status:
	$(AWS_CLI) cloudformation describe-stacks \
		--stack-name $(AWSTCL_TEST_STACK) \
		--region     $(AWS_REGION) \
		--query 'Stacks[0].StackStatus' \
		--output text

.PHONY: deploy-fixtures fixture-events seed-fixtures fixtures \
	empty-fixtures-bucket teardown-fixtures fixture-status
