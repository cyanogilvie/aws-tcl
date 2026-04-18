DESTDIR=
PREFIX=/usr/local
PACKAGE_NAME=aws
VER=2.0a19
MODE=-ziplet
TCLSH=tclsh

# Fixture stack lifecycle
AWSTCL_TEST_STACK?=aws-tcl-test
AWS_REGION?=us-east-1
AWS_CLI?=aws
FIXTURE_TEMPLATE=tests/fixtures/aws-tcl-test.json

CONTAINER_ENV=-v "`pwd`/here:/here" --network host --ulimit core=-1

all: tm

tm: tm/aws-$(VER).tm
	cp api/hmac-0.1.tm tm

tm/aws-$(VER).tm: aws.tcl build.tcl
	mkdir -p tm/aws
	#mkdir -p tm/aws1
	#cp api/*.tm tm/
	#cp api/aws1/*.tm tm/aws1/
	cp aws.tcl tm/aws-$(VER).tm
	$(TCLSH) build.tcl -ver $(VER) $(MODE) -definitions botocore/botocore/data -prefix tm || rm rm/aws-$(VER).tm

test: tm
#	docker run --rm --name aws-tcl-test \
#		-v "`pwd`/tests:/tests" \
#		-v "`pwd`/tm:/tests/tm" \
#		-v "$(HOME)/.aws:/root/.aws" \
#		alpine-tcl:test \
#		/tests/all.tcl $(TESTFLAGS)
	$(TCLSH) tests/all.tcl $(TESTFLAGS) -load "apply {ver {source tests/load_self.tcl}} $(VER)"

vim-gdb: tm
	vim -c 'packadd termdebug' -c 'set mouse=a' -c 'set number' -c 'set foldlevel=100' -c 'Termdebug -ex set\ print\ pretty\ on --args $(TCLSH) tests/all.tcl -singleproc 1 -load apply\ {ver\ {source\ tests/load_self.tcl}}\ $(VER) $(TESTFLAGS)' -c "2windo set nonumber" -c "1windo set nonumber"

container_test: tm
	docker run --rm --name aws-tcl-test \
		-v "`pwd`/tests:/tests" \
		-v "`pwd`/tm:/tests/tm" \
		-v "$(HOME)/.aws:/root/.aws" \
		cyanogilvie/alpine-tcl:v0.9.77-stripped \
		/tests/all.tcl $(TESTFLAGS)

install: tm
	mkdir -p $(DESTDIR)$(PREFIX)/lib/tcl8/site-tcl
	mkdir -p $(DESTDIR)$(PREFIX)/lib/tcl9/site-tcl
	cp -a tm/* $(DESTDIR)$(PREFIX)/lib/tcl8/site-tcl/
	cp -a tm/* $(DESTDIR)$(PREFIX)/lib/tcl9/site-tcl/

clean:
	-rm -r tm

# Fixture stack lifecycle <<<
# See tests/fixtures/README.md for the full story. These targets assume the
# AWS CLI is installed and the ambient credentials have rights to
# create/modify the test stack (IAM managed policies, S3 bucket, SSM
# parameters, CloudWatch log groups).

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

seed-fixtures: tm
	AWSTCL_TEST_STACK=$(AWSTCL_TEST_STACK) AWS_REGION=$(AWS_REGION) \
		$(TCLSH) tests/fixtures/seed_objects.tcl

fixtures: deploy-fixtures seed-fixtures

empty-fixtures-bucket: tm
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
# Fixture stack lifecycle >>>

.PHONY: clean tm container_test test install all \
	deploy-fixtures seed-fixtures fixtures empty-fixtures-bucket teardown-fixtures fixture-status fixture-events
