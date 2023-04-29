ARG ALPINE_VER="3.17.3"

FROM alpine:$ALPINE_VER as base-amd64
# Since Nov 2020 Lambda has supported AVX2 (and haswell) in all regions except China
ARG CFLAGS="-O3 -march=haswell"

FROM alpine:$ALPINE_VER as base-arm64
# Target graviton2
ARG CFLAGS="-O3 -moutline-atomics -march=armv8.2-a"

FROM alpine:$ALPINE_VER as base-armv7
ARG CFLAGS="-O3"

# alpine-tcl-build <<<
ARG TARGETARCH
# alpine-tcl-build-base <<<
FROM base-$TARGETARCH AS alpine-tcl-build-base
ARG CFLAGS
RUN apk add --no-cache --update build-base autoconf automake bsd-compat-headers bash ca-certificates libssl1.1 libcrypto1.1 docker-cli git libtool python3 pandoc pkgconfig
RUN git config --global advice.detachedHead false

# tcl: tip of core-8-branch
WORKDIR /src/tcl
RUN wget https://core.tcl-lang.org/tcl/tarball/93f005c985/tcl.tar.gz -O - | tar xz --strip-components=1
RUN cd /src/tcl/unix && \
    ./configure CFLAGS="${CFLAGS}" --enable-64bit --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries install-tzdata install-packages install-headers install-private-headers && \
    cp ../libtommath/tommath.h /usr/local/include/ && \
    ln -s /usr/local/bin/tclsh8.7 /usr/local/bin/tclsh && \
    make clean && \
    mkdir /usr/local/lib/tcl8/site-tcl && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# tclconfig: tip of trunk
WORKDIR /src
RUN wget https://core.tcl-lang.org/tclconfig/tarball/ed5ac018e8/tclconfig.tar.gz -O - | tar xz

# thread: tip of thread-2-branch
WORKDIR /src/thread
RUN apk add --no-cache --update zip
RUN wget https://core.tcl-lang.org/thread/tarball/61e980ef5c/thread.tar.gz -O - | tar xz --strip-components=1
RUN ln -s ../tclconfig && autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols
RUN make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# alpine-tcl-build-base >>>

# package-jitc <<<
FROM alpine-tcl-build-base AS package-jitc
WORKDIR /src/jitc
RUN apk add --no-cache --update libstdc++ libgcc
RUN git clone -b v0.4 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/jitc .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols
RUN make tcc tools
RUN make DESTDIR=/out install-binaries install-libraries
# package-jitc >>>
# package-pgwire <<<
FROM alpine-tcl-build-base AS package-pgwire
WORKDIR /src/pgwire
RUN git clone -b v3.0.0b21 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/pgwire .
WORKDIR /src/pgwire/src
RUN make all && \
	mkdir -p /out/usr/local/lib/tcl8/site-tcl && \
    cp -a tm/* /out/usr/local/lib/tcl8/site-tcl
# package-pgwire >>>
# package-dedup <<<
FROM alpine-tcl-build-base AS package-dedup
WORKDIR /src/dedup
RUN git clone --recurse-submodules --shallow-submodules --branch v0.9.5 --single-branch --depth 1 https://github.com/cyanogilvie/dedup .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make DESTDIR=/out install-binaries install-libraries clean && \
    cp /out/usr/local/lib/dedup*/dedupConfig.sh /out/usr/local/lib/
# package-dedup >>>
# package-reuri <<<
FROM alpine-tcl-build-base AS package-reuri
WORKDIR /src/reuri
RUN git clone -b v0.10 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/reuri .
COPY --link --from=package-dedup /out /
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols
RUN make tools
#RUN make DESTDIR=/out pgo install-binaries install-libraries clean
RUN make DESTDIR=/out install-binaries install-libraries clean
# package-reuri >>>
# package-rl_http <<<
FROM alpine-tcl-build-base AS package-rl_http
WORKDIR /src/rl_http
RUN git clone -b 1.14.9 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/RubyLane/rl_http .
RUN make DESTDIR=/out install
# package-rl_http >>>
# package-brotli <<<
FROM alpine-tcl-build-base AS package-brotli
WORKDIR /src/brotli
RUN apk add --no-cache --update brotli-libs
RUN apk add --no-cache --update --virtual build-dependencies git brotli-dev
RUN git clone -q -b v0.3.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/tcl-brotli .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make DESTDIR=/out install-binaries install-libraries clean
# package-brotli >>>
# package-rltest <<<
FROM alpine-tcl-build-base AS package-rltest
WORKDIR /src/rltest
RUN git clone -b v1.5.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/RubyLane/rltest .
RUN make DESTDIR=/out install-tm
# pacakge-rltest>>>
# package-names <<<
FROM alpine-tcl-build-base AS package-names
WORKDIR /src/names
RUN git clone -b v0.1.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/names .
RUN make test && make DESTDIR=/out install-tm
# package-names >>>
# package-prng <<<
FROM alpine-tcl-build-base AS package-prng
WORKDIR /src/prng
RUN git clone -b v0.7.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/prng .
RUN make test && make DESTDIR=/out install-tm
# package-prng >>>
# package-sqlite3 <<<
FROM alpine-tcl-build-base AS package-sqlite3
WORKDIR /src/sqlite3
RUN wget https://sqlite.org/2023/sqlite-autoconf-3410200.tar.gz -O - | tar xz --strip-components=1
WORKDIR /src/sqlite3/tea
RUN autoconf && ./configure CFLAGS="${CFLAGS}" && \
    make DESTDIR=/out all install-binaries install-libraries clean
# package-sqlite3 >>>
# package-pixel <<<
# pHash
FROM alpine-tcl-build-base AS package-pixel
RUN apk add --no-cache --update cmake boost-dev libjpeg-turbo-dev libpng-dev tiff-dev libjpeg-turbo-dev libexif-dev libpng-dev librsvg-dev libwebp-dev imlib2-dev
#	libjpeg-turbo libexif libpng librsvg libwebp imlib2
WORKDIR /src/phash
RUN wget https://github.com/aetilius/pHash/archive/dea9ffc.tar.gz -O - | tar xz --strip-components=1
RUN apk manifest cmake
RUN cmake -DPHASH_DYNAMIC=ON -DPHASH_STATIC=OFF . && \
	make install && \
	cp -a third-party/CImg/* /usr/local/include

# Pixel: tip of master
WORKDIR /src/pixel
RUN git clone -q -b v3.5.3 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/pixel .
WORKDIR /src/pixel/pixel_core
RUN ln -s /src/tclconfig && \
	autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make -j 8 all && \
	make install-binaries install-libraries && \
	make DESTDIR=/out install-binaries install-libraries && \
	cp pixelConfig.sh /usr/local/lib && \
	cp pixelConfig.sh /out/usr/local/lib 
WORKDIR /src/pixel/pixel_jpeg
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make DESTDIR=/out install-binaries install-libraries clean
WORKDIR /src/pixel/pixel_png
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make DESTDIR=/out install-binaries install-libraries clean
WORKDIR /src/pixel/pixel_svg_cairo
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make DESTDIR=/out install-binaries install-libraries clean
WORKDIR /src/pixel/pixel_webp
RUN ln -s /src/tclconfig && \
	autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make DESTDIR=/out install-binaries install-libraries clean
WORKDIR /src/pixel/pixel_imlib2
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make DESTDIR=/out install-binaries install-libraries clean
WORKDIR /src/pixel/pixel_phash
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make DESTDIR=/out install-binaries install-libraries clean
# package-pixel >>>
# package-tdom <<<
FROM alpine-tcl-build-base AS package-tdom
# gumbo (not a tcl package, needed for tdom)
WORKDIR /src/gumbo
RUN wget https://github.com/google/gumbo-parser/archive/v0.10.1.tar.gz -O - | tar xz --strip-components=1
RUN ./autogen.sh && \
	./configure CFLAGS="${CFLAGS}" --enable-static=no && \
	make -j 8 all && \
	make install && \
	make DESTDIR=/out install

# tdom - fork with RL changes and extra stubs exports and misc
WORKDIR /src/tdom
RUN git clone -b cyan-0.9.3.2 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/RubyLane/tdom .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols --enable-html5 && \
    make -j 8 all && \
    make DESTDIR=/out install-binaries install-libraries
# package-tdom >>>
# package-parse_args <<<
FROM alpine-tcl-build-base AS package-parse_args
WORKDIR /src/parse_args
RUN git clone --recurse-submodules --shallow-submodules --branch v0.3.4.1 --single-branch --depth 1 https://github.com/RubyLane/parse_args .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make DESTDIR=/out install-binaries install-libraries clean
# package-parse_args >>>
# package-rl_json <<<
FROM alpine-tcl-build-base AS package-rl_json
WORKDIR /src/rl_json
RUN git clone --recurse-submodules --shallow-submodules --branch 0.12.2 --single-branch --depth 1 https://github.com/RubyLane/rl_json .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make DESTDIR=/out install-binaries install-libraries clean
# package-rl_json >>>
# package-hash <<<
FROM alpine-tcl-build-base AS package-hash
WORKDIR /src/hash
RUN git clone -b v0.3.2 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/hash .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make DESTDIR=/out install-binaries install-libraries clean
# package-hash >>>
# package-unix_sockets <<<
FROM alpine-tcl-build-base AS package-unix_sockets
WORKDIR /src/unix_sockets
RUN git clone -b v0.2.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/unix_sockets .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make DESTDIR=/out install-binaries install-libraries clean
# package-unix_sockets >>>
# package-tclreadline <<<
FROM alpine-tcl-build-base AS package-tclreadline
WORKDIR /src/tclreadline
RUN apk add --no-cache --update readline readline-dev
RUN git clone -b v2.3.8.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/tclreadline .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --without-tk && \
	rm libtool && ln -s /usr/bin/libtool
RUN make DESTDIR=/out LIBTOOL=/usr/bin/libtool install-libLTLIBRARIES install-tclrlSCRIPTS && \
	mv /out/usr/local/lib/libtclreadline* /out/usr/local/lib/tclreadline2.3.8.1/
COPY tcl/tclshrc /out/root/.tclshrc
# package-tclreadline >>>
# package-tclsignal <<<
FROM alpine-tcl-build-base AS package-tclsignal
WORKDIR /src/tclsignal
RUN git clone -b v1.4.4.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/tclsignal .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make -j 8 all && \
	make DESTDIR=/out install-binaries install-libraries clean
# package-tclsignal >>>
# package-type <<<
FROM alpine-tcl-build-base AS package-type
WORKDIR /src/type
RUN git clone -q -b v0.2.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/type .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make DESTDIR=/out install-binaries install-libraries clean
# package-type >>>
# package-inotify <<<
FROM alpine-tcl-build-base AS package-inotify
WORKDIR /src/inotify
RUN git clone -q -b v2.2.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/inotify .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make DESTDIR=/out install-binaries install-libraries clean
# package-inotify >>>
# package-parsetcl <<<
FROM alpine-tcl-build-base AS package-parsetcl
COPY --link --from=package-tdom /out /
WORKDIR /src/parsetcl
RUN git clone -q -b v0.1.2 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/parsetcl .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make DESTDIR=/out install-binaries install-libraries clean
# package-parsetcl >>>
# package-ck <<<
FROM alpine-tcl-build-base AS package-ck
RUN apk add --no-cache --update ncurses-libs ncurses-dev
WORKDIR /src/ck
RUN git clone -q -b v8.6.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/ck .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make DESTDIR=/out install-binaries install-libraries clean && \
	cp -a library /out/usr/local/lib/ck8.6/
# package-ck >>>
# package-chantricks <<<
FROM alpine-tcl-build-base AS package-chantricks
WORKDIR /src/chantricks
RUN git clone --recurse-submodules --shallow-submodules --branch v1.0.4 --single-branch --depth 1 https://github.com/cyanogilvie/chantricks .
RUN make DESTDIR=/out install-tm
# package-chantricks >>>
# package-openapi <<<
FROM alpine-tcl-build-base AS package-openapi
WORKDIR /src/openapi
RUN git clone --recurse-submodules --shallow-submodules --branch v0.4.11 --single-branch --depth 1 https://github.com/cyanogilvie/tcl-openapi .
RUN mkdir -p /out/usr/local/lib/tcl8/site-tcl && \
	cp *.tm /out/usr/local/lib/tcl8/site-tcl
# package-openapi >>>
# package-resolve <<<
FROM alpine-tcl-build-base AS package-resolve
WORKDIR /src/resolve
RUN git clone --recurse-submodules --shallow-submodules --branch v0.10 --single-branch --depth 1 https://github.com/cyanogilvie/resolve .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make DESTDIR=/out install-binaries install-libraries clean
# package-resolve >>>
# package-tcllib <<<
FROM alpine-tcl-build-base AS package-tcllib
WORKDIR /src/tcllib
RUN wget https://core.tcl-lang.org/tcllib/uv/tcllib-1.21.tar.gz -O - | tar xz --strip-components=1
RUN ./configure && make DESTDIR=/out install-libraries install-applications clean
# package-tcllib >>>
# package-docker <<<
FROM alpine-tcl-build-base AS package-docker
COPY --link --from=package-chantricks	/out /
COPY --link --from=package-openapi		/out /
COPY --link --from=package-rl_json		/out /
COPY --link --from=package-parse_args	/out /
COPY --link --from=package-tcllib		/out /
WORKDIR /src/docker
RUN git clone --recurse-submodules --shallow-submodules --branch v0.9.1 --single-branch --depth 1 https://github.com/cyanogilvie/tcl-docker-client .
RUN make DESTDIR=/out TM_MODE=-ziplet install-tm
# package-docker >>>
# package-gc_class <<<
FROM alpine-tcl-build-base AS package-gc_class
WORKDIR /src/gc_class
RUN git clone --recurse-submodules --shallow-submodules --branch v1.0 --single-branch --depth 1 https://github.com/RubyLane/gc_class .
RUN mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp gc_class*.tm /out/usr/local/lib/tcl8/site-tcl
# package-gc_class >>>
# package-tbuild <<<
FROM alpine-tcl-build-base AS package-tbuild
WORKDIR /src/tbuild
RUN git clone --recurse-submodules --shallow-submodules --branch v0.5 --single-branch --depth 1 https://github.com/cyanogilvie/tbuild .
RUN mkdir -p /out/usr/local/bin && \
	cp tbuild-lite.tcl /out/usr/local/bin/tbuild-lite && \
	chmod +x /out/usr/local/bin/tbuild-lite
# package-tbuild >>>
# package-cflib <<<
FROM alpine-tcl-build-base AS package-cflib
COPY --link --from=package-tbuild /out /
WORKDIR /src/cflib
RUN git clone --recurse-submodules --shallow-submodules --branch 1.16.1 --single-branch --depth 1 https://github.com/cyanogilvie/cflib .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-cflib >>>
# package-sop <<<
FROM alpine-tcl-build-base AS package-sop
COPY --link --from=package-tbuild /out /
WORKDIR /src/sop
RUN git clone --recurse-submodules --shallow-submodules --branch 1.7.2 --single-branch --depth 1 https://github.com/cyanogilvie/sop .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-sop >>>
# package-netdgram <<<
FROM alpine-tcl-build-base AS package-netdgram
COPY --link --from=package-tbuild /out /
WORKDIR /src/netdgram
RUN git clone --recurse-submodules --shallow-submodules --branch v0.9.12 --single-branch --depth 1 https://github.com/cyanogilvie/netdgram .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp -a tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-netdgram >>>
# package-evlog <<<
FROM alpine-tcl-build-base AS package-evlog
COPY --link --from=package-tbuild /out /
WORKDIR /src/evlog
RUN git clone --recurse-submodules --shallow-submodules --branch v0.3.1 --single-branch --depth 1 https://github.com/cyanogilvie/evlog .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-evlog >>>
# package-dsl <<<
FROM alpine-tcl-build-base AS package-dsl
COPY --link --from=package-tbuild /out /
WORKDIR /src/dsl
RUN git clone --recurse-submodules --shallow-submodules --branch v0.5 --single-branch --depth 1 https://github.com/cyanogilvie/dsl .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-dsl >>>
# package-logging <<<
FROM alpine-tcl-build-base AS package-logging
COPY --link --from=package-tbuild /out /
WORKDIR /src/logging
RUN git clone --recurse-submodules --shallow-submodules --branch v0.3 --single-branch --depth 1 https://github.com/cyanogilvie/logging .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-logging >>>
# package-crypto <<<
FROM alpine-tcl-build-base AS package-crypto
COPY --link --from=package-tbuild /out /
WORKDIR /src/crypto
RUN git clone --recurse-submodules --shallow-submodules --branch 0.6 --single-branch --depth 1 https://github.com/cyanogilvie/crypto .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-crypto >>>
# package-datasource <<<
FROM alpine-tcl-build-base AS package-datasource
COPY --link --from=package-tbuild /out /
WORKDIR /src/datasource
RUN git clone --recurse-submodules --shallow-submodules --branch v0.2.4 --single-branch --depth 1 https://github.com/cyanogilvie/datasource .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-datasource >>>
# package-m2 <<<
FROM alpine-tcl-build-base AS package-m2
COPY --link --from=package-tbuild /out /
WORKDIR /src/m2
#RUN git clone --recurse-submodules --shallow-submodules --branch v0.43.15 --single-branch --depth 1 https://github.com/cyanogilvie/m2 .
RUN git clone --branch v0.43.15 --single-branch --depth 1 https://github.com/cyanogilvie/m2 .
RUN mkdir -p /out/usr/local/lib/tcl8/site-tcl && \
	tbuild-lite build_tm m2 && \
	cp -r tm/tcl/*			/out/usr/local/lib/tcl8/site-tcl/ && \
	mkdir -p				/out/usr/local/opt/m2 && \
	cp -r m2_node			/out/usr/local/opt/m2/ && \
	cp -r tools				/out/usr/local/opt/m2/ && \
	cp -r authenticator		/out/usr/local/opt/m2/ && \
	cp -r admin_console		/out/usr/local/opt/m2/ && \
	mkdir -p				/out/etc/codeforge/authenticator && \
	cp -r plugins			/out/etc/codeforge/authenticator/
COPY m2/m2_node				/out/usr/local/bin/
COPY m2/authenticator		/out/usr/local/bin/
COPY m2/m2_keys				/out/usr/local/bin/
COPY m2/m2_admin_console	/out/usr/local/bin/
# package-m2 >>>
# package-tdbc <<<
# tip of connection-pool-git branch
FROM alpine-tcl-build-base AS package-tdbc
WORKDIR /src/tdbc
RUN wget https://github.com/cyanogilvie/tdbc/archive/1f8b684.tar.gz -O - | tar xz --strip-components=1
RUN ln -s ../tclconfig && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make DESTDIR=/out install-binaries install-libraries clean
# package-tdbc >>>
# package-tcltls <<<
FROM alpine-tcl-build-base AS package-tcltls
WORKDIR /src/tcltls
RUN apk add --no-cache --update --virtual build-dependencies curl openssl-dev curl-dev
RUN wget https://core.tcl-lang.org/tcltls/tarball/tls-1-7-22/tcltls.tar.gz -O - | tar xz --strip-components=1
RUN ./autogen.sh && \
    ./configure CFLAGS="${CFLAGS}" --prefix=/usr/local --libdir=/usr/local/lib --disable-sslv2 --disable-sslv3 --disable-tlsv1.0 --disable-tlsv1.1 --enable-ssl-fastpath --enable-symbols && \
    make -j 8 all && \
    make DESTDIR=/out install clean
# package-tcltls >>>
# package-sockopt <<<
FROM alpine-tcl-build-base AS package-sockopt
COPY --link --from=package-rl_json /out /
WORKDIR /src/sockopt
RUN git clone --recurse-submodules --shallow-submodules --branch v0.2.1 --single-branch --depth 1 https://github.com/cyanogilvie/sockopt .
RUN autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make DESTDIR=/out install-binaries install-libraries clean
# package-sockopt >>>
# package-tty <<<
FROM alpine-tcl-build-base AS package-tty
RUN apk add --no-cache --update ncurses
WORKDIR /src/tty
RUN git clone --recurse-submodules --shallow-submodules --branch v0.6.1 --single-branch --depth 1 https://github.com/cyanogilvie/tcl-tty .
RUN make DESTDIR=/out install-tm
# package-tty >>>
# package-flock <<<
FROM alpine-tcl-build-base AS package-flock
WORKDIR /src/flock
RUN git clone --recurse-submodules --shallow-submodules --branch v0.6.1 --single-branch --depth 1 https://github.com/cyanogilvie/flock .
RUN make DESTDIR=/out install
# package-flock >>>
# package-aio <<<
FROM alpine-tcl-build-base AS package-aio
WORKDIR /src/aio
RUN git clone --recurse-submodules --shallow-submodules --branch v1.7.1 --single-branch --depth 1 https://github.com/cyanogilvie/aio .
RUN make test && \
	make DESTDIR=/out install-tm
# package-aio >>>
# package-aws <<<
FROM alpine-tcl-build-base AS package-aws
COPY --link --from=package-tdom			/out /
COPY --link --from=package-parse_args	/out /
COPY --link --from=package-rl_json		/out /
COPY --link --from=package-hash			/out /
COPY --link --from=package-dedup		/out /
COPY --link --from=package-reuri		/out /
COPY --link --from=package-resolve		/out /
COPY --link --from=package-gc_class		/out /
COPY --link --from=package-rl_http		/out /
COPY --link --from=package-tcllib		/out /
COPY --link --from=package-chantricks	/out /
COPY api/botocore /src/botocore
WORKDIR /src/botocore
COPY api/build.tcl /src/botocore
COPY api/*.tm /tmp/tm/
COPY api/aws1/*.tm /tmp/tm/aws1/
ARG TESTMODE
RUN if test -z "$TESTMODE"; \
	then \
		mkdir -p /out/usr/local/lib/tcl8/site-tcl; \
		cp -a /tmp/tm/* /usr/local/lib/tcl8/site-tcl; \
		cp -a /tmp/tm/* /out/usr/local/lib/tcl8/site-tcl; \
		tclsh build.tcl -definitions botocore/data -prefix /out/usr/local/lib/tcl8/site-tcl; \
	fi
# package-aws >>>

FROM alpine-tcl-build-base AS alpine-tcl-build
COPY --link --from=package-rl_http		/out /
COPY --link --from=package-dedup		/out /
COPY --link --from=package-jitc			/out /
COPY --link --from=package-pgwire		/out /
COPY --link --from=package-reuri		/out /
COPY --link --from=package-brotli		/out /
COPY --link --from=package-rltest		/out /
COPY --link --from=package-names		/out /
COPY --link --from=package-prng			/out /
COPY --link --from=package-sqlite3		/out /
COPY --link --from=package-pixel		/out /
COPY --link --from=package-tdom			/out /
COPY --link --from=package-parse_args	/out /
COPY --link --from=package-rl_json		/out /
COPY --link --from=package-hash			/out /
COPY --link --from=package-unix_sockets	/out /
COPY --link --from=package-tclreadline	/out /
COPY --link --from=package-tclsignal	/out /
COPY --link --from=package-type			/out /
COPY --link --from=package-inotify		/out /
COPY --link --from=package-parsetcl		/out /
COPY --link --from=package-ck			/out /
COPY --link --from=package-resolve		/out /
COPY --link --from=package-tcllib		/out /
COPY --link --from=package-tdbc			/out /
COPY --link --from=package-tcltls		/out /
COPY --link --from=package-sockopt		/out /
COPY --link --from=package-chantricks	/out /
COPY --link --from=package-openapi		/out /
COPY --link --from=package-docker		/out /
COPY --link --from=package-gc_class		/out /
COPY --link --from=package-tbuild		/out /
COPY --link --from=package-cflib		/out /
COPY --link --from=package-sop			/out /
COPY --link --from=package-netdgram		/out /
COPY --link --from=package-evlog		/out /
COPY --link --from=package-dsl			/out /
COPY --link --from=package-logging		/out /
COPY --link --from=package-crypto		/out /
COPY --link --from=package-datasource	/out /
COPY --link --from=package-m2			/out /
COPY --link --from=package-tty			/out /
COPY --link --from=package-flock		/out /
COPY --link --from=package-aio			/out /
COPY --link --from=package-aws			/out /

# misc local bits
COPY tcl/tm /usr/local/lib/tcl8/site-tcl
COPY tools/* /usr/local/bin/

# common_sighandler
COPY common_sighandler-*.tm /usr/local/lib/tcl8/site-tcl/

# meta
#RUN /usr/local/bin/package_report
# alpine-tcl-build >>>

# alpine-tcl-gdb <<<
FROM alpine-tcl-build as alpine-tcl-gdb
RUN apk add --no-cache --update gdb vim
WORKDIR /here
# alpine-tcl-gdb >>>

# alpine-tcl-build-stripped <<<
FROM alpine-tcl-build as alpine-tcl-build-stripped
RUN find /usr -name "*.so" -exec strip {} \;
# alpine-tcl-build-stripped >>>

# alpine-tcl <<<
FROM alpine:$ALPINE_VER AS alpine-tcl
RUN apk add --no-cache --update musl-dev readline libjpeg-turbo libexif libpng libwebp tiff ncurses ncurses-libs libstdc++ libgcc brotli && \
	rm /usr/lib/libc.a
COPY --from=alpine-tcl-build /usr/local /usr/local
COPY --from=alpine-tcl-build /root/.tclshrc /root/
WORKDIR /here
VOLUME /here
ENTRYPOINT ["tclsh"]
# alpine-tcl >>>

# alpine-tcl-stripped <<<
FROM alpine:$ALPINE_VER AS alpine-tcl-stripped
RUN apk add --no-cache --update musl-dev readline libjpeg-turbo libexif libpng libwebp tiff ncurses ncurses-libs libstdc++ libgcc && \
	rm /usr/lib/libc.a
COPY --from=alpine-tcl-build-stripped /usr/local /usr/local
COPY --from=alpine-tcl-build-stripped /root/.tclshrc /root/
WORKDIR /here
VOLUME /here
ENTRYPOINT ["tclsh"]
# alpine-tcl >>>

# m2 <<<
FROM alpine-tcl AS m2
RUN mkdir -p /etc/codeforge/authenticator/keys/env && \
	mkdir -p /etc/codeforge/authenticator/svc_keys && \
	mkdir -p /etc/codeforge/authenticator/plugins && \
	mkdir -p /var/lib/codeforge/authenticator
COPY config/authenticator.conf /etc/codeforge
COPY m2/m2_entrypoint /usr/local/bin/
COPY m2/m2_node /usr/local/bin/
COPY m2/authenticator /usr/local/bin/
COPY --from=alpine-tcl-build /etc/codeforge/authenticator/plugins /etc/codeforge/authenticator/plugins
EXPOSE 5300
EXPOSE 5301
EXPOSE 5350
#VOLUME /etc/codeforge
#VOLUME /var/lib/codeforge
VOLUME /tmp/m2
ENTRYPOINT ["m2_entrypoint"]
# m2 >>>

# m2-stripped <<<
FROM alpine-tcl-stripped AS m2-stripped
RUN mkdir -p /etc/codeforge/authenticator/keys/env && \
	mkdir -p /etc/codeforge/authenticator/svc_keys && \
	mkdir -p /etc/codeforge/authenticator/plugins && \
	mkdir -p /var/lib/codeforge/authenticator
COPY config/authenticator.conf /etc/codeforge
COPY m2/m2_entrypoint /usr/local/bin/
COPY m2/m2_node /usr/local/bin/
COPY m2/authenticator /usr/local/bin/
COPY --from=alpine-tcl-build /etc/codeforge/authenticator/plugins /etc/codeforge/authenticator/plugins
EXPOSE 5300
EXPOSE 5301
EXPOSE 5350
#VOLUME /etc/codeforge
#VOLUME /var/lib/codeforge
VOLUME /tmp/m2
ENTRYPOINT ["m2_entrypoint"]
# m2-stripped >>>

# vim: foldmethod=marker foldmarker=<<<,>>>
