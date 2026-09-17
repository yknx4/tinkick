ARG POSTGRES_IMAGE=postgres:18.6-trixie@sha256:4ef4dbc939d61acea57712655ddb4b4ab27419c913f94cca0cd57cb3ea3c2280

FROM rust:1.96.0-slim-trixie@sha256:c37af730be4fd8104cbf9aedbd6ab259e51ca2d5437817a0f8680edf66ac6c28 AS rust

FROM ${POSTGRES_IMAGE} AS builder

COPY --from=rust /usr/local/cargo /usr/local/cargo
COPY --from=rust /usr/local/rustup /usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    PATH=/usr/local/cargo/bin:${PATH}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates clang git libclang-dev libssl-dev pkg-config \
        "postgresql-server-dev-18=${PG_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

RUN cargo install cargo-pgrx --version 0.19.1 --locked \
    && cargo pgrx init --pg18=/usr/lib/postgresql/18/bin/pg_config

WORKDIR /build/lead
ARG LEAD_COMMIT=0e29dbe5177bb64d027d6afeaa20eb0b46536be6
RUN git init . \
    && git remote add origin https://github.com/planetscale/lead.git \
    && git fetch --depth 1 origin "${LEAD_COMMIT}" \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${LEAD_COMMIT}"

RUN PGRX_BUILD_FLAGS=--locked cargo pgrx package \
    --package tin --no-default-features --features pg18 \
    --pg-config /usr/lib/postgresql/18/bin/pg_config --out-dir /out

FROM ${POSTGRES_IMAGE}

COPY --from=builder /out/ /
COPY --from=builder /build/lead/LICENSE /usr/share/doc/lead/LICENSE
