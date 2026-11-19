# syntax=docker/dockerfile:1
FROM node:26-bookworm-slim AS frontend
WORKDIR /build/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --ignore-scripts
COPY frontend/index.html frontend/tsconfig.json frontend/vite.config.ts ./
COPY frontend/src ./src
RUN npm run build

FROM debian:trixie-slim AS toolchain
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends ca-certificates curl xz-utils build-essential pkg-config libcurl4-openssl-dev python3 openssl && rm -rf /var/lib/apt/lists/*
ARG ZIG_VERSION=0.17.1
ARG ZIG_SHA256=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
RUN curl --proto '=https' --proto-redir '=https' -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"
WORKDIR /build
COPY build.zig build.zig.zon ./
COPY src ./src
# Unit tests depend only on Zig source, not on frontend bundles or documentation.
FROM toolchain AS unit
RUN zig build test

# Compile the shipped binary once, then test that exact optimized executable.
FROM toolchain AS build
COPY --from=frontend /build/frontend/dist ./frontend/dist
RUN zig build -Doptimize=ReleaseSafe

FROM build AS test
COPY tests ./tests
COPY integrations ./integrations
COPY docs/example-input.json ./docs/example-input.json
RUN python3 tests/api_smoke.py
RUN python3 tests/observe_contract.py
RUN python3 tests/controller_contract.py
RUN python3 tests/ownership_contract.py

FROM debian:trixie-slim AS runtime
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends ca-certificates libcurl4t64 curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 prontarr && useradd --uid 10001 --gid prontarr --no-create-home prontarr \
    && mkdir /data && chown prontarr:prontarr /data
COPY --from=test /build/zig-out/bin/prontarr /usr/local/bin/prontarr
COPY LICENSE THIRD_PARTY_NOTICES /usr/share/licenses/prontarr/
LABEL org.opencontainers.image.title="Prontarr" \
      org.opencontainers.image.description="A watchable copy now. A better one later." \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/JonasBrother97/prontarr"
ENV PRONTARR_DB=/data/prontarr.sqlite PRONTARR_BIND=0.0.0.0
WORKDIR /data
USER 10001:10001
EXPOSE 5882
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD curl --fail --silent http://127.0.0.1:5882/api/health || exit 1
ENTRYPOINT ["/usr/local/bin/prontarr"]
