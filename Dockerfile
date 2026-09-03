# syntax=docker/dockerfile:1
FROM debian:bookworm AS build
ARG ZIG_VERSION=0.16.0
ARG QJS_REPO=quickjs-ng/quickjs
ARG QJS_TAG=v0.16.2
ARG QJS_SHA256=
ARG BEARSSL_VERSION=0.6
ARG BEARSSL_SHA256=6705bba1714961b41a728dfc5debbe348d2966c117649392f8c8139efc83ff14
ARG TARGETARCH
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates xz-utils && rm -rf /var/lib/apt/lists/*
RUN ARCH=$(uname -m) && curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz && mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:$PATH"
COPY . .
RUN curl -fL "https://github.com/${QJS_REPO}/archive/refs/tags/${QJS_TAG}.tar.gz" -o /tmp/qjs.tar.gz \
  && if [ -n "${QJS_SHA256}" ]; then echo "${QJS_SHA256}  /tmp/qjs.tar.gz" | sha256sum -c -; fi \
  && rm -rf vendor/quickjs \
  && mkdir -p /tmp/qjs-src vendor/quickjs \
  && tar -xzf /tmp/qjs.tar.gz -C /tmp/qjs-src --strip-components=1 \
  && cp /tmp/qjs-src/*.h vendor/quickjs/ \
  && cp /tmp/qjs-src/quickjs.c /tmp/qjs-src/libregexp.c /tmp/qjs-src/libunicode.c /tmp/qjs-src/dtoa.c vendor/quickjs/ \
  && rm -rf /tmp/qjs-src /tmp/qjs.tar.gz
RUN curl -fsSL -o /tmp/bearssl.tar.gz "https://www.bearssl.org/bearssl-${BEARSSL_VERSION}.tar.gz" \
  && echo "${BEARSSL_SHA256}  /tmp/bearssl.tar.gz" | sha256sum -c - \
  && rm -rf vendor/bearssl \
  && mkdir -p /tmp/bearssl-src \
  && tar -xzf /tmp/bearssl.tar.gz -C /tmp/bearssl-src --strip-components=1 \
  && mkdir -p vendor/bearssl \
  && cp -r /tmp/bearssl-src/src /tmp/bearssl-src/inc vendor/bearssl/ \
  && printf '#ifndef FF_BEARSSL_BRIDGE_H\n#define FF_BEARSSL_BRIDGE_H\n\n#include "bearssl.h"\n\n#endif\n' > vendor/bearssl/zig_bridge.h \
  && rm -rf /tmp/bearssl-src /tmp/bearssl.tar.gz
RUN case "${TARGETARCH}" in \
      arm64) ZT=aarch64-linux-musl ;; \
      *)     ZT=x86_64-linux-musl ;; \
    esac && zig build -Doptimize=ReleaseFast -Dtarget=${ZT}
FROM alpine:3.20
RUN apk add --no-cache ca-certificates
RUN adduser -D -u 1000 app
WORKDIR /app
COPY --from=build /app/zig-out/bin/ff /usr/local/bin/ff
USER app
