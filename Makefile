VER=v0.9.28

all: alpine-tcl m2

alpine-tcl: Dockerfile
	docker build --target alpine-tcl-build -t alpine-tcl-build .
	docker build --target alpine-tcl -t cyanogilvie/alpine-tcl:$(VER) .
	docker build --target alpine-tcl-stripped -t cyanogilvie/alpine-tcl:$(VER)-stripped .

m2: Dockerfile
	docker build --target m2 -t cyanogilvie/m2:$(VER) .
	docker build --target m2-stripped -t cyanogilvie/m2:$(VER)-stripped .

upload: alpine-tcl m2
	docker push cyanogilvie/alpine-tcl:$(VER)-stripped
	docker push cyanogilvie/m2:$(VER)-stripped

package_report: alpine-tcl
	docker run --rm -v "`pwd`/tools:/tools" alpine-tcl-build /tools/package_report

.PHONY: alpine-tcl m2 package_report upload
