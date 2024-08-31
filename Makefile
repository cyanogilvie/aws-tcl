DESTDIR=
PREFIX=/usr/local
PACKAGE_NAME=aws
VER=2.0a17
MODE=-ziplet
TCLSH=tclsh

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
	cp -a tm/* $(DESTDIR)$(PREFIX)/lib/tcl8/site-tcl/

clean:
	-rm -r tm

.PHONY: clean tm container_test test install all
