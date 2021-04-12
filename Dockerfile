# Since Nov 2020 Lambda has supported AVX2 (and haswell) in all regions except China
ARG CFLAGS="-O3 -march=haswell"
#ARG CFLAGS="-O3 -mavx2"

# alpine-tcl-build <<<
FROM alpine:3.13.4 AS alpine-tcl-build
ARG CFLAGS
# tcl_version: tip of core-8-branch
ENV tcl_source="https://core.tcl-lang.org/tcl/tarball/99b8ad35a258cade/tcl.tar.gz"
# tclconfig: tip of trunk
ENV tclconfig_source="https://core.tcl-lang.org/tclconfig/tarball/8423a50147/tclconfig.tar.gz"
# thread: tip of thread-2-8-branch
ENV thread_source="https://core.tcl-lang.org/thread/tarball/2a83440579/thread.tar.gz"
# tdbc - tip of connection-pool-git branch
ENV tdbc_source="https://github.com/cyanogilvie/tdbc/archive/1f8b684.tar.gz"
# pgwire - tip of master
ENV pgwire_source="https://github.com/cyanogilvie/pgwire/archive/cc8b3d4.tar.gz"
# tdom - tip of master
ENV tdom_source="https://github.com/RubyLane/tdom/archive/d94dceb.tar.gz"
# tcltls
ENV tcltls_source="https://core.tcl-lang.org/tcltls/tarball/tls-1-7-22/tcltls.tar.gz"
# parse_args - tip of master
ENV parse_args_source="https://github.com/RubyLane/parse_args/archive/aeeaf39.tar.gz"
# rl_json - tip of master
ENV rl_json_source="https://github.com/RubyLane/rl_json/archive/c5a8033.tar.gz"
# hash - tip of master
ENV hash_source="https://github.com/cyanogilvie/hash/archive/79c2066.tar.gz"
# unix_sockets - tip of master
ENV unix_sockets_source="https://github.com/cyanogilvie/unix_sockets/archive/761daa5.tar.gz"
# tcllib
ENV tcllib_source="https://core.tcl-lang.org/tcllib/uv/tcllib-1.20.tar.gz"
# gc_class - tip of master
ENV gc_class_source="https://github.com/RubyLane/gc_class/archive/f295f65.tar.gz"
# rl_http - tip of master
ENV rl_http_source="https://github.com/RubyLane/rl_http/archive/e38f67b.tar.gz"
# sqlite3
ENV sqlite3_source="https://sqlite.org/2021/sqlite-autoconf-3350400.tar.gz"
# tcc4tcl - tip of master
ENV tcc4tcl_source="https://github.com/cyanogilvie/tcc4tcl/archive/b8171e0.tar.gz"

RUN apk add --no-cache build-base autoconf automake bsd-compat-headers bash ca-certificates libssl1.1 libcrypto1.1
# tcl
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
# tclconfig
WORKDIR /src
RUN wget $tclconfig_source -O - | tar xz
# thread
WORKDIR /src/thread
RUN wget $thread_source -O - | tar xz --strip-components=1 && \
    ln -s ../tclconfig && \
    autoconf && \
    ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# tdbc
WORKDIR /src/tdbc
RUN wget $tdbc_source -O - | tar xz --strip-components=1 && \
    ln -s ../tclconfig && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# pgwire
WORKDIR /src/pgwire
RUN wget $pgwire_source -O - | tar xz --strip-components=1 && \
    cd src && \
    make all && \
    cp -a tm/* /usr/local/lib/tcl8/site-tcl && \
    make clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# tdom
WORKDIR /src/tdom
RUN wget $tdom_source -O - | tar xz --strip-components=1 && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# tcltls
WORKDIR /src/tcltls
RUN apk add --no-cache --virtual build-dependencies curl openssl-dev curl-dev && \
    wget $tcltls_source -O - | tar xz --strip-components=1 && \
    ./autogen.sh && \
    ./configure CFLAGS="${CFLAGS}" --prefix=/usr/local --libdir=/usr/local/lib --disable-sslv2 --disable-sslv3 --disable-tlsv1.0 --disable-tlsv1.1 --enable-ssl-fastpath --enable-symbols && \
    make -j 8 all && \
    make install clean && \
    apk del build-dependencies && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# parse_args
WORKDIR /src/parse_args
RUN wget $parse_args_source -O - | tar xz --strip-components=1 && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# rl_json
WORKDIR /src/rl_json
RUN wget $rl_json_source -O - | tar xz --strip-components=1 && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# hash
WORKDIR /src/hash
RUN wget $hash_source -O - | tar xz --strip-components=1 && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# unix_sockets
WORKDIR /src/unix_sockets
RUN wget $unix_sockets_source -O - | tar xz --strip-components=1 && \
    autoconf && ./configure CFLAGS="${CFLAGS}" --enable-symbols && \
    make -j 8 all && \
    make install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# tcllib
WORKDIR /src/tcllib
RUN wget $tcllib_source -O - | tar xz --strip-components=1 && \
    ./configure && \
    make install-libraries install-applications clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# gc_class
WORKDIR /src/gc_class
RUN wget $gc_class_source -O - | tar xz --strip-components=1 && \
    cp gc_class*.tm /usr/local/lib/tcl8/site-tcl && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# rl_http
WORKDIR /src/rl_http
RUN wget $rl_http_source -O - | tar xz --strip-components=1 && \
    cp rl_http*.tm /usr/local/lib/tcl8/site-tcl && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# sqlite3
WORKDIR /src/sqlite3
RUN wget $sqlite3_source -O - | tar xz --strip-components=1 && \
    cd tea && \
    autoconf && ./configure CFLAGS="${CFLAGS}" && \
    make all install-binaries install-libraries clean && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# tcc4tcl
WORKDIR /src/tcc4tcl
RUN wget $tcc4tcl_source -O - | tar xz --strip-components=1 && \
    apk add --no-cache --virtual build-dependencies openssl && \
    build/pre.sh && \
    sed --in-place -e 's/^typedef __builtin_va_list \(.*\)/#if defined(__GNUC__) \&\& __GNUC__ >= 3\ntypedef __builtin_va_list \1\n#else\ntypedef char* \1\n#endif/g' /usr/include/bits/alltypes.h && \
    sed --in-place -e 's/@@VERS@@/0.30.1/g' configure.ac Makefile.in tcc4tcl.tcl && \
    autoconf && \
    ./configure --prefix=/usr/local && \
    make -j 8 all && \
    make install && \
    apk del build-dependencies && \
    find . -type f -not -name '*.c' -and -not -name '*.h' -delete
# aws-tcl
COPY api/* /usr/local/lib/tcl8/site-tcl/
# alpine-tcl-build >>>

# alpine-tcl <<<
FROM alpine:3.13.4 AS alpine-tcl
RUN apk add --no-cache musl-dev
# Need to fix glibc-ism for tcc4tcl to work
RUN sed --in-place -e 's/^typedef __builtin_va_list \(.*\)/#if defined(__GNUC__) \&\& __GNUC__ >= 3\ntypedef __builtin_va_list \1\n#else\ntypedef char* \1\n#endif/g' /usr/include/bits/alltypes.h
COPY --from=alpine-tcl-build /usr/local /usr/local
# alpine-tcl >>>

# alpine-tcl-lambda <<<
FROM alpine-tcl AS alpine-tcl-lambda
WORKDIR /usr/local/bin
ADD https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/download/v1.0/aws-lambda-rie /usr/local/bin/
RUN chmod +x aws-lambda-rie
COPY lambda/entry.sh /usr/local/bin/
COPY lambda/bootstrap /usr/local/bin/
RUN mkdir /opt/extensions
WORKDIR /var/task
VOLUME /var/task
ENV LAMBDA_TASK_ROOT=/var/task
ENTRYPOINT ["/usr/local/bin/entry.sh"]
CMD ["app.handler"] 
# alpine-tcl-lambda >>>

# vim: foldmethod=marker foldmarker=<<<,>>>
