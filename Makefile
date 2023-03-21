VER=v0.9.65
PLATFORM=linux/arm64,linux/amd64
DEST=--push
TCLSH=tclsh

CONTAINER_ENV = -v "`pwd`/here:/here" --network host --ulimit core=-1

all: alpine-tcl m2

alpine-tcl: Dockerfile
	#docker buildx build --target alpine-tcl-build --platform linux/amd64 -t alpine-tcl-build .
	#docker buildx build --target alpine-tcl --platform linux/amd64 -t cyanogilvie/alpine-tcl:$(VER) .
	docker buildx build $(DEST) --target alpine-tcl-stripped --platform $(PLATFORM) -t cyanogilvie/alpine-tcl:$(VER)-stripped .

alpine-tcl-gdb: Makefile Dockerfile
	docker buildx build $(DEST) --build-arg TESTMODE=1 --target alpine-tcl-gdb --platform $(PLATFORM) -t cyanogilvie/alpine-tcl:$(VER)-gdb .

alpine-tcl-test: Dockerfile
	docker buildx build --load --target alpine-tcl -t alpine-tcl:test .
	touch alpine-tcl-test

m2: Dockerfile
	docker buildx build --target m2 --platform linux/amd64 -t cyanogilvie/m2:$(VER) .
	docker buildx build --target m2-stripped --platform linux/amd64 -t cyanogilvie/m2:$(VER)-stripped .

upload: alpine-tcl m2
	docker push cyanogilvie/alpine-tcl:$(VER)-stripped
	#docker push cyanogilvie/alpine-tcl:$(VER)
	docker push cyanogilvie/m2:$(VER)-stripped

package_report: alpine-tcl
	docker run --rm -v "`pwd`/tools:/tools" alpine-tcl-build /tools/package_report

gdb:
	echo "/tmp/cores" | sudo tee /proc/sys/kernel/core_pattern
	docker buildx build --target alpine-tcl-gdb --platform linux/amd64 -t alpine-tcl-gdb .
	docker run --rm -it --init --name rl-nsadmin --cap-add=SYS_PTRACE --security-opt seccomp=unconfined $(CONTAINER_ENV) alpine-tcl-gdb

aws-lambda-rie-arm64:
	wget https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/download/v1.9/aws-lambda-rie-arm64
	chmod +x aws-lambda-rie-arm64

aws-lambda-rie-x86_64:
	wget https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/download/v1.9/aws-lambda-rie-x86_64
	chmod +x aws-lambda-rie-x86_64

lambdatest-arm64: aws-lambda-rie-arm64
	VER="$(VER)" PLATFORM=linux/arm64 RIE=aws-lambda-rie-arm64 docker-compose down
	VER="$(VER)" PLATFORM=linux/arm64 RIE=aws-lambda-rie-arm64 docker-compose run --rm test tests/all.tcl $(TESTFLAGS)
	VER="$(VER)" PLATFORM=linux/arm64 RIE=aws-lambda-rie-arm64 docker-compose logs lambda
	VER="$(VER)" PLATFORM=linux/arm64 RIE=aws-lambda-rie-arm64 docker-compose down

lambdatest-amd64: aws-lambda-rie-x86_64
	VER="$(VER)" PLATFORM=linux/amd64 RIE=aws-lambda-rie-x86_64 docker-compose down
	VER="$(VER)" PLATFORM=linux/amd64 RIE=aws-lambda-rie-x86_64 docker-compose run --rm test tests/all.tcl $(TESTFLAGS)
	VER="$(VER)" PLATFORM=linux/amd64 RIE=aws-lambda-rie-x86_64 docker-compose logs lambda
	VER="$(VER)" PLATFORM=linux/amd64 RIE=aws-lambda-rie-x86_64 docker-compose down

tm/aws-2.0a3.tm: api/aws-2.0a3.tm api/build.tcl
	mkdir -p tm/aws1
	cp api/*.tm tm/
	cp api/aws1/*.tm tm/aws1/
	$(TCLSH) api/build.tcl -definitions botocore/botocore/data -prefix tm

tm: tm/aws-2.0a3.tm

test: tm alpine-tcl-test
	docker run --rm --name aws-tcl-test \
		-v "`pwd`/tests:/tests" \
		-v "`pwd`/tm:/tests/tm" \
		-v "$(HOME)/.aws:/root/.aws" \
		alpine-tcl:test \
		/tests/all.tcl $(TESTFLAGS)

clean:
	-rm -r aws-lambda-rie-arm64 aws-lamda-rie-x86_64 tm

.PHONY: alpine-tcl alpine-tcl-gdb m2 package_report upload gdb clean lambdatest-arm64 lambdatest-amd64 tm
