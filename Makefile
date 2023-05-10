DESTDIR=
PREFIX=/usr/local
PACKAGE_NAME=aws
VER=2.0a5
MODE=-ziplet
TCLSH=tclsh

CONTAINER_ENV=-v "`pwd`/here:/here" --network host --ulimit core=-1

all: tm

tm: tm/aws-$(VER).tm

tm/aws-$(VER).tm: aws.tcl build.tcl
	mkdir -p tm/aws
	cp aws.tcl tm/aws-$(VER).tm
	#mkdir -p tm/aws1
	#cp api/*.tm tm/
	#cp api/aws1/*.tm tm/aws1/
	$(TCLSH) build.tcl -ver $(VER) $(MODE) -definitions botocore/botocore/data -prefix tm

test: tm
#	docker run --rm --name aws-tcl-test \
#		-v "`pwd`/tests:/tests" \
#		-v "`pwd`/tm:/tests/tm" \
#		-v "$(HOME)/.aws:/root/.aws" \
#		alpine-tcl:test \
#		/tests/all.tcl $(TESTFLAGS)
	$(TCLSH) tests/all.tcl $(TESTFLAGS) -load "apply {ver {source tests/load_self.tcl}} $(VER)"

install: tm
	mkdir -p $(DESTDIR)$(PREFIX)/lib/tcl8/site-tcl
	cp -a tm/* $(DESTDIR)$(PREFIX)/lib/tcl8/site-tcl/

clean:
	-rm -r tm

.PHONY: clean tm
