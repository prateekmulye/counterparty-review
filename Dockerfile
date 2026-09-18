# Source and checksum from https://www.haproxy.org/download/3.2/src/.
FROM python:3.13.15-slim-bookworm@sha256:ed86c82274b3c69b52fb5820f358f0bd7df0b603332063cb5c6e32bd220c3e6e AS proxy
RUN apt-get update && apt-get install -y --no-install-recommends gcc make libc6-dev curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN curl --fail --silent --show-error --location --proto '=https' \
      https://www.haproxy.org/download/3.2/src/haproxy-3.2.23.tar.gz -o haproxy.tar.gz \
    && echo '82d14ef33571e4edeb9197516c0d058a3775fb80541e46afe4377428e461fef0  haproxy.tar.gz' | sha256sum -c - \
    && tar -xzf haproxy.tar.gz --strip-components=1 \
    && make -j2 TARGET=linux-glibc USE_THREAD=1 \
    && strip haproxy

FROM hexpm/elixir:1.18.5-erlang-27.3.4.17-debian-bookworm-20260824@sha256:5217a6fa6f81a83f261724ed30c7f83d825bc436f85c660e290b0643344d376d AS build
# QEMU cannot reliably invalidate dual-mapped JIT code. Enable only for emulated builds.
# https://www.erlang.org/docs/27/apps/erts/erl_cmd.html
ARG ERL_BUILD_SINGLE_MAPPING=false
ENV MIX_ENV=prod ERL_FLAGS="+JMsingle ${ERL_BUILD_SINGLE_MAPPING}"
WORKDIR /build
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config ./config
RUN mix deps.get --only prod && mix deps.compile
COPY lib ./lib
COPY priv ./priv
COPY agent/main.py ./agent/main.py
RUN mix compile --warnings-as-errors && mix release

FROM python:3.13.15-slim-bookworm@sha256:ed86c82274b3c69b52fb5820f358f0bd7df0b603332063cb5c6e32bd220c3e6e AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 libncurses6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8080 \
    AI_PROVIDER=workers-ai AI_GATEWAY_URL=https://ai.prateekmulye.dev/v1/infer \
    PUBLIC_ORIGIN=https://counterparty.prateekmulye.dev \
    ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1 +A 2" RELEASE_DISTRIBUTION=none
WORKDIR /app
COPY --from=build /build/_build/prod/rel/counterparty_review ./
COPY --from=proxy /build/haproxy /usr/local/sbin/haproxy
COPY --from=proxy /build/haproxy.tar.gz /usr/share/doc/haproxy/source.tar.gz
COPY Dockerfile /usr/share/doc/haproxy/Dockerfile
COPY deploy ./deploy
RUN /usr/local/sbin/haproxy -c -f /app/deploy/haproxy.cfg
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=4s --start-period=30s --retries=3 CMD python -c "import urllib.request; r=urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8080/health',headers={'Host':'counterparty.prateekmulye.dev'}),timeout=3); assert r.status == 200"
ENTRYPOINT ["python", "-B", "/app/deploy/run.py"]
CMD ["/app/bin/counterparty_review", "start"]
