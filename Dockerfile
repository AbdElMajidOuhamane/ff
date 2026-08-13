# syntax=docker/dockerfile:1
FROM debian:bookworm AS build
ARG ZIG_VERSION=0.16.0
ARG V8_ZIG_VERSION=v0.5.2
ARG V8_VERSION=14.9.207.35
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN ARCH=$(uname -m) \
    && curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig \
    && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:$PATH"

COPY . .

ARG TARGETARCH
RUN case "$TARGETARCH" in \
      arm64) SUFFIX=aarch64 ;; \
      amd64) SUFFIX=x86_64 ;; \
      *) echo "unsupported arch: $TARGETARCH"; exit 1 ;; \
    esac \
    && mkdir -p vendor/v8/linux \
    && curl -fL -o vendor/v8/linux/libc_v8.a \
       "https://github.com/lightpanda-io/zig-v8-fork/releases/download/${V8_ZIG_VERSION}/libc_v8_${V8_VERSION}_linux_${SUFFIX}.a"

RUN case "$TARGETARCH" in \
      arm64) TGT=aarch64-linux-gnu ;; \
      amd64) TGT=x86_64-linux-gnu ;; \
    esac \
    && zig build -Doptimize=ReleaseFast -Dtarget=$TGT -Dv8-linux

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 1000 --create-home app
WORKDIR /app
COPY --from=build /app/zig-out/bin/ff /usr/local/bin/ff
COPY examples/ /app/examples/
USER app
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/ff"]
