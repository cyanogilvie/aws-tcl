ARG ALPINE_VER="3.16.3"

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
FROM base-$TARGETARCH AS alpine-tcl-build
ARG CFLAGS
RUN apk add --no-cache --update build-base autoconf automake bsd-compat-headers bash ca-certificates libssl1.1 libcrypto1.1 docker-cli git
RUN git config --global advice.detachedHead false
# tcl: tip of core-8-branch
ENV tcl_source="https://core.tcl-lang.org/tcl/tarball/99b8ad35a258cade/tcl.tar.gz"
WORKDIR /src/tcl
RUN wget $tcl_source -O - | tar xz --strip-components=1 && \
    cd /src/tcl/unix && \
    ./configure CFLAGS="${CFLAGS}" --enable-64bit --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries install-tzdata install-packages install-headers install-private-headers && \
    cp ../libtommath/tommath.h /usr/local/include/ && \
    ln -s /usr/local/bin/tclsh8.7 /usr/local/bin/tclsh && \
    make clean && \
    mkdir /usr/local/lib/tcl8/site-tcl && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# tclconfig: tip of trunk
ENV tclconfig_source="https://core.tcl-lang.org/tclconfig/tarball/1f17dfd726292dc4/tclconfig.tar.gz"
WORKDIR /src
RUN wget $tclconfig_source -O - | tar xz
# thread: tip of thread-2-8-branch
ENV thread_source="https://core.tcl-lang.org/thread/tarball/2a83440579/thread.tar.gz"
WORKDIR /src/thread
RUN wget $thread_source -O - | tar xz --strip-components=1 && \
    ln -s ../tclconfig && \
    autoconf && \
    ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# tdbc - tip of connection-pool-git branch
ENV tdbc_source="https://github.com/cyanogilvie/tdbc/archive/1f8b684.tar.gz"
WORKDIR /src/tdbc
RUN wget $tdbc_source -O - | tar xz --strip-components=1 && \
    ln -s ../tclconfig && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# tcltls
ENV tcltls_source="https://core.tcl-lang.org/tcltls/tarball/tls-1-7-22/tcltls.tar.gz"
WORKDIR /src/tcltls
RUN apk add --no-cache --update --virtual build-dependencies curl openssl-dev curl-dev && \
    wget $tcltls_source -O - | tar xz --strip-components=1 && \
    ./autogen.sh && \
    ./configure CFLAGS="${CFLAGS}" --prefix=/usr/local --libdir=/usr/local/lib --disable-sslv2 --disable-sslv3 --disable-tlsv1.0 --disable-tlsv1.1 --enable-ssl-fastpath --enable-symbols && \
    make -j 8 all && \
    make install clean && \
    apk del build-dependencies && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# parse_args
ENV parse_args_source="https://github.com/RubyLane/parse_args/archive/v0.3.4.tar.gz"
WORKDIR /src
RUN git clone --recurse-submodules --shallow-submodules --branch v0.3.4.1 --single-branch --depth 1 https://github.com/RubyLane/parse_args && \
	cd parse_args && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# rl_json - tip of master
ENV rl_json_source="https://github.com/RubyLane/rl_json/archive/0.11.5.tar.gz"
WORKDIR /src
RUN git clone --recurse-submodules --shallow-submodules --branch 0.11.5.1 --single-branch --depth 1 https://github.com/RubyLane/rl_json && \
	cd rl_json && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# hash - tip of master
ENV hash_source="https://github.com/cyanogilvie/hash"
WORKDIR /src/hash
RUN git clone -b v0.3.2 --recurse-submodules --shallow-submodules --single-branch --depth 1 $hash_source . && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# unix_sockets - tip of master
ENV unix_sockets_source="https://github.com/cyanogilvie/unix_sockets/archive/761daa5.tar.gz"
WORKDIR /src/unix_sockets
RUN wget $unix_sockets_source -O - | tar xz --strip-components=1 && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# tcllib
ENV tcllib_source="https://core.tcl-lang.org/tcllib/uv/tcllib-1.20.tar.gz"
WORKDIR /src/tcllib
RUN wget $tcllib_source -O - | tar xz --strip-components=1 && \
    ./configure && \
    make install-libraries install-applications clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# gc_class - tip of master
ENV gc_class_source="https://github.com/RubyLane/gc_class/archive/f295f65.tar.gz"
WORKDIR /src/gc_class
RUN wget $gc_class_source -O - | tar xz --strip-components=1 && \
    cp gc_class*.tm /usr/local/lib/tcl8/site-tcl && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# rl_http
ENV rl_http_source="https://github.com/RubyLane/rl_http/archive/1.14.4.tar.gz"
WORKDIR /src/rl_http
RUN wget $rl_http_source -O - | tar xz --strip-components=1 && \
	make install && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# sqlite3
ENV sqlite3_source="https://sqlite.org/2021/sqlite-autoconf-3350400.tar.gz"
WORKDIR /src/sqlite3
RUN wget $sqlite3_source -O - | tar xz --strip-components=1 && \
    cd tea && \
    autoconf && ./configure CFLAGS="${CFLAGS}" && \
    make all install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
## tcc4tcl - tip of master
#ENV tcc4tcl_source="https://github.com/cyanogilvie/tcc4tcl/archive/b8171e0.tar.gz"
#WORKDIR /src/tcc4tcl
#RUN wget $tcc4tcl_source -O - | tar xz --strip-components=1 && \
#    apk add --no-cache --update --virtual build-dependencies openssl && \
#    build/pre.sh && \
#    sed --in-place -e 's/^typedef __builtin_va_list \(.*\)/#if defined(__GNUC__) \&\& __GNUC__ >= 3\ntypedef __builtin_va_list \1\n#else\ntypedef char* \1\n#endif/g' /usr/include/bits/alltypes.h && \
#    sed --in-place -e 's/@@VERS@@/0.30.1/g' configure.ac Makefile.in tcc4tcl.tcl && \
#    autoconf && \
#    ./configure --prefix=/usr/local && \
#    make -j 8 all && \
#    make install && \
#    apk del build-dependencies && \
#    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# Codeforge packages and applications up to m2
# tbuild - tip of master
ENV tbuild_source="https://github.com/cyanogilvie/tbuild/archive/e526a9c.tar.gz"
WORKDIR /src/tbuild
RUN wget $tbuild_source -O - | tar xz --strip-components=1 && \
	cp tbuild-lite.tcl /usr/local/bin/tbuild-lite && \
	chmod +x /usr/local/bin/tbuild-lite && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# cflib
ENV cflib_source="https://github.com/cyanogilvie/cflib/archive/1.15.2.tar.gz"
WORKDIR /src/cflib
RUN wget $cflib_source -O - | tar xz --strip-components=1 && \
	tbuild-lite && cp tm/tcl/* /usr/local/lib/tcl8/site-tcl/ && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# sop - tip of master
ENV sop_source="https://github.com/cyanogilvie/sop/archive/1.7.2.tar.gz"
WORKDIR /src/sop
RUN wget $sop_source -O - | tar xz --strip-components=1 && \
	tbuild-lite && cp tm/tcl/* /usr/local/lib/tcl8/site-tcl/ && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# netdgram - tip of master
ENV netdgram_source="https://github.com/cyanogilvie/netdgram/archive/v0.9.12.tar.gz"
WORKDIR /src/netdgram
RUN wget $netdgram_source -O - | tar xz --strip-components=1 && \
	tbuild-lite && cp -r tm/tcl/* /usr/local/lib/tcl8/site-tcl/ && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# evlog - tip of master
ENV evlog_source="https://github.com/cyanogilvie/evlog/archive/c6c2529.tar.gz"
WORKDIR /src/evlog
RUN wget $evlog_source -O - | tar xz --strip-components=1 && \
	tbuild-lite build_tm evlog && cp -r tm/tcl/* /usr/local/lib/tcl8/site-tcl/ && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# dsl - tip of master
ENV dsl_source="https://github.com/cyanogilvie/dsl/archive/v0.5.tar.gz"
WORKDIR /src/dsl
RUN wget $dsl_source -O - | tar xz --strip-components=1 && \
	tbuild-lite && cp -r tm/tcl/* /usr/local/lib/tcl8/site-tcl/ && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# logging - tip of master
ENV logging_source="https://github.com/cyanogilvie/logging/archive/e709389.tar.gz"
WORKDIR /src/logging
RUN wget $logging_source -O - | tar xz --strip-components=1 && \
	tbuild-lite && cp -r tm/tcl/* /usr/local/lib/tcl8/site-tcl/ && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# sockopt - tip of master
ENV sockopt_source="https://github.com/cyanogilvie/sockopt/archive/c574d92.tar.gz"
WORKDIR /src/sockopt
RUN wget $sockopt_source -O - | tar xz --strip-components=1 && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# crypto - tip of master
ENV crypto_source="https://github.com/cyanogilvie/crypto/archive/7a04540.tar.gz"
WORKDIR /src/crypto
RUN wget $crypto_source -O - | tar xz --strip-components=1 && \
	tbuild-lite build_tm crypto && cp -r tm/tcl/* /usr/local/lib/tcl8/site-tcl/ && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# common_sighandler
COPY common_sighandler-*.tm /usr/local/lib/tcl8/site-tcl/
# m2
ENV m2_source="https://github.com/cyanogilvie/m2/archive/v0.43.15.tar.gz"
WORKDIR /src/m2
RUN wget $m2_source -O - | tar xz --strip-components=1 && \
	tbuild-lite build_tm m2 && cp -r tm/tcl/* /usr/local/lib/tcl8/site-tcl/ && \
	mkdir -p /usr/local/opt/m2 && \
	cp -r m2_node /usr/local/opt/m2/ && \
	cp -r tools /usr/local/opt/m2/ && \
	cp -r authenticator /usr/local/opt/m2/ && \
	cp -r admin_console /usr/local/opt/m2/ && \
	mkdir -p /etc/codeforge/authenticator && \
	cp -r plugins /etc/codeforge/authenticator/ && \
	find . -type f -not -name '*.c' -and -not -name '*.h' -delete
COPY m2/m2_node /usr/local/bin/
COPY m2/authenticator /usr/local/bin/
COPY m2/m2_keys /usr/local/bin/
COPY m2/m2_admin_console /usr/local/bin/
# datasource - tip of master
ENV datasource_source="https://github.com/cyanogilvie/datasource/archive/v0.2.4.tar.gz"
WORKDIR /src/datasource
RUN wget $datasource_source -O - | tar xz --strip-components=1 && \
	tbuild-lite && cp -r tm/tcl/* /usr/local/lib/tcl8/site-tcl/ && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# tools

# tclreadline
WORKDIR /src/tclreadline
ENV tclreadline_source="https://github.com/cyanogilvie/tclreadline/archive/v2.3.8.1.tar.gz"
RUN apk add --no-cache --update readline && \
	apk add --no-cache --update --virtual build-dependencies readline-dev && \
	wget $tclreadline_source -O - | tar xz --strip-components=1 && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --without-tk && \
    make install-libLTLIBRARIES install-tclrlSCRIPTS && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete && \
	apk del --no-cache build-dependencies
COPY tcl/tclshrc /root/.tclshrc

## expect: tip of trunk
#ENV expect_source="https://core.tcl-lang.org/expect/tarball/f8e8464f14/expect.tar.gz"
#WORKDIR /src/tcl
#RUN wget $expect_source -O - | tar xz --strip-components=1 && \
#    ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
#    make -j 8 all && \
#    make install-binaries install-libraries && \
#    make clean && \
#    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# tclsignal
ENV tclsignal_source="https://github.com/cyanogilvie/tclsignal/archive/v1.4.4.1.tar.gz"
WORKDIR /src/tclsignal
RUN wget $tclsignal_source -O - | tar xz --strip-components=1 && \
	autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make -j 8 all && \
	make install-binaries install-libraries clean && \
	find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# type
ENV type_source="https://github.com/cyanogilvie/type/archive/v0.2.tar.gz"
WORKDIR /src/type
RUN wget $type_source -O - | tar xz --strip-components=1 && \
	ln -s /src/tclconfig && \
	autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make install-binaries install-libraries clean && \
	find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# inotify: tip of master
ENV inotify_source="https://github.com/cyanogilvie/inotify/archive/298f608.tar.gz"
WORKDIR /src/inotify
RUN wget $inotify_source -O - | tar xz --strip-components=1 && \
	ln -s /src/tclconfig && \
	autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make install-binaries install-libraries clean && \
	find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# pHash: tip of master
ENV phash_source="https://github.com/aetilius/pHash/archive/dea9ffc.tar.gz"
WORKDIR /src/phash
RUN apk add --no-cache --update cmake boost-dev libjpeg-turbo-dev libpng-dev tiff-dev
RUN wget $phash_source -O - | tar xz --strip-components=1
RUN apk manifest cmake
RUN cmake -DPHASH_DYNAMIC=ON -DPHASH_STATIC=OFF . && \
	make install && \
	cp -a third-party/CImg/* /usr/local/include && \
	find . -type f -not -name '*.c' -and -not -name '*.cpp' -and  -name '*.h' -delete

# Pixel: tip of master
ENV pixel_source="https://github.com/cyanogilvie/pixel"
WORKDIR /src/pixel
RUN apk add --no-cache --update libjpeg-turbo libexif libpng librsvg libwebp imlib2 && \
	apk add --no-cache --update --virtual build-dependencies libjpeg-turbo-dev libexif-dev libpng-dev librsvg-dev libwebp-dev imlib2-dev
RUN git clone -q -b v3.5.3 --recurse-submodules --shallow-submodules --single-branch --depth 1 $pixel_source .
RUN cd pixel_core && \
		ln -s /src/tclconfig && \
		autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
		make -j 8 install-binaries install-libraries && \
		cp pixelConfig.sh /usr/local/lib && \
	cd ../pixel_jpeg && \
		autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
		make install-binaries install-libraries clean && \
	cd ../pixel_png && \
		autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
		make install-binaries install-libraries clean && \
	cd ../pixel_svg_cairo && \
		autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
		make install-binaries install-libraries clean && \
	cd ../pixel_webp && \
		ln -s /src/tclconfig && \
		autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
		make install-binaries install-libraries clean && \
	cd ../pixel_imlib2 && \
		autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
		make install-binaries install-libraries clean && \
	cd ../pixel_phash && \
		autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
		make install-binaries install-libraries clean && \
	cd ../pixel_core && \
		make clean && \
	cd .. && \
	apk del --no-cache build-dependencies && \
	find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# chantricks
ENV chantricks_source="https://github.com/cyanogilvie/chantricks/archive/v1.0.3.tar.gz"
WORKDIR /src/chantricks
RUN wget $chantricks_source -O - | tar xz --strip-components=1 && \
	make install-tm && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# openapi
ENV openapi_source="https://github.com/cyanogilvie/tcl-openapi/archive/v0.4.11.tar.gz"
WORKDIR /src/openapi
RUN wget $openapi_source -O - | tar xz --strip-components=1 && \
	cp *.tm /usr/local/lib/tcl8/site-tcl && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# docker
ENV docker_source="https://github.com/cyanogilvie/tcl-docker-client/archive/v0.9.0.tar.gz"
WORKDIR /src/docker
RUN wget $docker_source -O - | tar xz --strip-components=1 && \
	make TM_MODE=-ziplet install-tm && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# gumbo (not a tcl package, needed for tdom)
ENV gumbo_source="https://github.com/google/gumbo-parser/archive/v0.10.1.tar.gz"
WORKDIR /src/gumbo
RUN wget $gumbo_source -O - | tar xz --strip-components=1 && \
	apk add --no-cache --update libtool && \
	./autogen.sh && \
	./configure CFLAGS="${CFLAGS}" --enable-static=no && \
	make -j 8 all && \
	make install && \
	make clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# tdom - fork with RL changes and extra stubs exports and misc
ENV tdom_source="https://github.com/RubyLane/tdom/archive/cyan-0.9.3.1.tar.gz"
WORKDIR /src/tdom
RUN wget $tdom_source -O - | tar xz --strip-components=1 && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols --enable-html5 && \
    make -j 8 all && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# tty
ENV tty_source="https://github.com/cyanogilvie/tcl-tty/archive/v0.5.tar.gz"
WORKDIR /src/tty
RUN apk add --no-cache --update ncurses && \
	wget $tty_source -O - | tar xz --strip-components=1 && \
	make install-tm && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# parsetcl - tip of master
ENV parsetcl_source="https://github.com/cyanogilvie/parsetcl/archive/030a1439b76747ec7a016c5bd0ae78c93fc9bb7b.tar.gz"
WORKDIR /src/parsetcl
RUN wget $parsetcl_source -O - | tar xz --strip-components=1 && \
	ln -s /src/tclconfig && \
	autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make install-binaries install-libraries clean && \
	find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# aws api, generated from the botocore repo json files
ENV botocore_source="https://github.com/boto/botocore/archive/refs/tags/1.27.96.tar.gz"
WORKDIR /src/botocore
RUN wget $botocore_source -O - | tar xz --strip-components=1
COPY api/build.tcl /src/botocore
COPY api/*.tm /usr/local/lib/tcl8/site-tcl/
COPY api/aws1/*.tm /usr/local/lib/tcl8/site-tcl/aws1/
RUN tclsh build.tcl -definitions botocore/data -prefix /usr/local/lib/tcl8/site-tcl && \
	rm -rf /src/botocore/*

# flock
ENV flock_source="https://github.com/cyanogilvie/flock/archive/v0.6.tar.gz"
WORKDIR /src/flock
RUN wget $flock_source -O - | tar xz --strip-components=1 && \
	make install && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# ck
ENV ck_source="https://github.com/cyanogilvie/ck/archive/v8.6.tar.gz"
WORKDIR /src/ck
RUN apk add --no-cache --update ncurses-libs && \
	apk add --no-cache --update --virtual build-dependencies ncurses-dev && \
	wget $ck_source -O - | tar xz --strip-components=1 && \
	ln -s /src/tclconfig && \
	autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
	make install-binaries install-libraries clean && \
	cp -a library /usr/local/lib/ck8.6/ && \
	apk del --no-cache build-dependencies && \
	find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# resolve
ENV resolve_source="https://github.com/cyanogilvie/resolve"
WORKDIR /src/resolve
RUN git clone --recurse-submodules --shallow-submodules --branch v0.10 --single-branch --depth 1 $resolve_source . && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# dedup
ENV dedup_source="https://github.com/cyanogilvie/dedup"
WORKDIR /src/dedup
RUN git clone --recurse-submodules --shallow-submodules --branch v0.9.4.2 --single-branch --depth 1 $dedup_source . && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# reuri
ENV reuri_source="https://github.com/cyanogilvie/reuri"
WORKDIR /src/reuri
RUN git clone -b v0.2.9.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 $reuri_source . && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols --with-dedup=/usr/local/lib/dedup0.9.4 && \
    #make pgo install-binaries install-libraries clean && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# brotli
ENV brotli_source="https://github.com/cyanogilvie/tcl-brotli"
WORKDIR /src/brotli
RUN apk add --no-cache --update brotli-libs && \
	apk add --no-cache --update --virtual build-dependencies git brotli-dev && \
	git clone -q -b v0.3.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 $brotli_source . && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make install-binaries install-libraries clean && \
	apk del --no-cache build-dependencies && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# aio
ENV aio_source="https://github.com/cyanogilvie/aio/archive/v1.7.tar.gz"
WORKDIR /src/aio
RUN wget $aio_source -O - | tar xz --strip-components=1 && \
	make test && \
	make install-tm && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# prng
ENV prng_source="https://github.com/cyanogilvie/prng/archive/v0.7.tar.gz"
WORKDIR /src/prng
RUN wget $prng_source -O - | tar xz --strip-components=1 && \
	make test && \
	make install-tm && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# names
ENV names_source="https://github.com/cyanogilvie/names/archive/v0.1.tar.gz"
WORKDIR /src/names
RUN wget $names_source -O - | tar xz --strip-components=1 && \
	make test && \
	make install-tm && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# rltest
ENV rltest_source="https://github.com/RubyLane/rltest/archive/v1.5.tar.gz"
WORKDIR /src/rltest
RUN wget $rltest_source -O - | tar xz --strip-components=1 && \
	make install-tm && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# jitc
ENV jitc_source="https://github.com/cyanogilvie/jitc"
WORKDIR /src/jitc
RUN apk add --no-cache --update --virtual build-dependencies git python3 && \
	apk add --no-cache --update libstdc++ libgcc && \
	git clone -b v0.2.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 $jitc_source . && \
	autoconf && \
	./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make install-binaries install-libraries clean && \
	apk del --no-cache build-dependencies && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# pgwire
ENV pgwire_source="https://github.com/cyanogilvie/pgwire"
WORKDIR /src/pgwire
RUN git clone -b v3.0.0b21 --recurse-submodules --shallow-submodules --single-branch --depth 1 $pgwire_source . && \
    cd src && \
    make all && \
    cp -a tm/* /usr/local/lib/tcl8/site-tcl && \
    make clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete

# misc local bits
COPY tcl/tm /usr/local/lib/tcl8/site-tcl
COPY tools/* /usr/local/bin/

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
RUN apk add --no-cache --update musl-dev readline libjpeg-turbo libexif libpng libwebp tiff ncurses ncurses-libs libstdc++ libgcc && \
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
