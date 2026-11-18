# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
#
#   - https://hub.docker.com/r/hexpm/elixir/tags
#   - https://hub.docker.com/_/debian?tab=tags&page=1&name=bookworm
#
# OTP must be >= 27.3: builds.hex.pm serves a chain whose intermediate carries
# both keyCertSign and an EKU of serverAuth, and older public_key rejects that
# pairing outright -- `mix local.hex` dies at image build with
# `unsupported_certificate ... key_usage_mismatch`. Verified: 27.1.3 and 27.2
# both fail, 27.3.4 succeeds. Don't pin this back down without testing
# `mix local.hex` in the image first.
#
# Final Track runs what it's developed and tested on: Elixir 1.20 / OTP 28. The
# Phoenix-generated config uses regex features (the `E` modifier in
# runtime.exs) that 1.18 rejects at boot — runtime.exs is evaluated whole,
# dev-only branches included.
ARG ELIXIR_VERSION=1.20.5
ARG OTP_VERSION=28.5.0.8
ARG DEBIAN_VERSION=bookworm-20261027-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} as builder

# install build dependencies. No Node: tailwind + esbuild are installed via
# mix. git: heroicons, daisyUI and neiam_auth are git deps.
RUN apt-get update -y \
    && apt-get install -y build-essential git ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib

COPY assets assets

# Compile the application *before* bundling assets so Phoenix LiveView's
# colocated hooks (the `phoenix-colocated/final_track` virtual package
# imported from js/app.js) exist on disk by the time esbuild runs.
RUN mix compile

RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

# rel/overlays supplies bin/server, bin/migrate, bin/invite and
# bin/invite-link; rel/env.sh.eex names the node for clustering. Without this the release
# still builds -- it just has no `server` in it -- and the container fails at
# CMD with "no such file or directory" and nothing else to go on.
COPY rel rel

RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
  apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates tini \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# Album covers (FinalTrack.Covers.Store, FINAL_TRACK_COVERS_DIR). In the
# cluster a shared volume is mounted here; owned by nobody so the release
# can write to it either way.
RUN mkdir -p /var/lib/final_track/covers && chown -R nobody /var/lib/final_track

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/final_track ./

USER nobody

# tini reaps zombies + forwards signals so PostgreSQL connections get
# closed cleanly on SIGTERM.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/server"]
