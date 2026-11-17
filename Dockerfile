# syntax=docker/dockerfile:1

###############################################################################
# Build stage — compiles the Elixir release and the digested static assets.
###############################################################################
FROM elixir:1.17-otp-27 AS builder

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates git curl \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod \
    DATABASE_PATH=/tmp/marsad-build.db \
    SECRET_KEY_BASE=build-time-placeholder-secret-key-base-not-for-production-use-000000000000 \
    MARSAD_VAULT_KEY=MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=

COPY mix.exs mix.lock ./
RUN mix deps.get

COPY config ./config
COPY assets ./assets
COPY lib ./lib
COPY priv ./priv

RUN mix assets.setup \
    && mix assets.deploy \
    && mix release

###############################################################################
# Runtime stage — slim image with only the compiled release.
###############################################################################
FROM debian:bookworm-slim AS runner

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system marsad \
    && useradd --system --gid marsad --home-dir /app --shell /usr/sbin/nologin marsad

WORKDIR /app
COPY --from=builder --chown=marsad:marsad /app/_build/prod/rel/marsad ./

RUN mkdir -p /data && chown -R marsad:marsad /data

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    RELEASE_NAME=marsad \
    PHX_SERVER=true \
    PHX_HOST=localhost \
    PORT=4000 \
    DATABASE_PATH=/data/marsad.db

USER marsad
EXPOSE 4000
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://localhost:${PORT}/offline >/dev/null || exit 1

CMD ["bin/marsad", "start"]
