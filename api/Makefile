TCLSH=tclsh

all: services

services:
	mkdir -p tm
	cp aws-2.* tm/
	$(TCLSH) build.tcl -definitions botocore/botocore/data -prefix tm -services "$(SERVICES)"

test: services
	$(TCLSH) tests/all.tcl $(TESTFLAGS) -load "tcl::tm::path add [file normalize [file join $$::tcltest::testsDirectory .. tm]]; package require aws 2"

clean:
	-rm -rf tm

.PHONY: all services clean test
