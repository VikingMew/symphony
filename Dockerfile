# syntax=docker/dockerfile:1

ARG ELIXIR_IMAGE=elixir:1.19-otp-28-slim
ARG NODE_IMAGE=node:22-bookworm-slim
ARG RUNTIME_IMAGE=debian:trixie-slim

FROM ${NODE_IMAGE} AS codex

ARG NPM_REGISTRY

RUN if [ -n "$NPM_REGISTRY" ]; then npm config set registry "$NPM_REGISTRY"; fi \
  && npm install --global @openai/codex

FROM ${NODE_IMAGE} AS worker

ARG APT_DEBIAN_MIRROR
ARG APT_SECURITY_MIRROR

RUN if [ -n "$APT_DEBIAN_MIRROR" ]; then \
      find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i "s|http://deb.debian.org/debian|${APT_DEBIAN_MIRROR}|g" {} +; \
    fi \
  && if [ -n "$APT_SECURITY_MIRROR" ]; then \
      find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i "s|http://deb.debian.org/debian-security|${APT_SECURITY_MIRROR}|g; s|http://security.debian.org/debian-security|${APT_SECURITY_MIRROR}|g" {} +; \
    fi

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    git \
    openssh-server \
    python3 \
    ripgrep \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --create-home --shell /bin/bash symphony \
  && install -d -m 755 /run/sshd /workspace \
  && install -d -o symphony -g symphony -m 700 /home/symphony/.ssh /home/symphony/.codex \
  && printf '%s\n' \
    'PasswordAuthentication no' \
    'PermitRootLogin no' \
    'PubkeyAuthentication yes' \
    'StrictModes no' \
    'AuthorizedKeysFile .ssh/authorized_keys' \
    'AcceptEnv *' \
    > /etc/ssh/sshd_config.d/symphony-worker.conf

RUN chown symphony:symphony /workspace

COPY --from=codex /usr/local/bin/node /usr/local/bin/node
COPY --from=codex /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN ln -s /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex \
  && ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
  && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]

FROM ${ELIXIR_IMAGE} AS build

ARG APT_DEBIAN_MIRROR
ARG APT_SECURITY_MIRROR
ARG HEX_MIRROR_URL

ENV MIX_ENV=prod
WORKDIR /app

RUN if [ -n "$APT_DEBIAN_MIRROR" ]; then \
      find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i "s|http://deb.debian.org/debian|${APT_DEBIAN_MIRROR}|g" {} +; \
    fi \
  && if [ -n "$APT_SECURITY_MIRROR" ]; then \
      find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i "s|http://deb.debian.org/debian-security|${APT_SECURITY_MIRROR}|g; s|http://security.debian.org/debian-security|${APT_SECURITY_MIRROR}|g" {} +; \
    fi

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force
RUN if [ -n "$HEX_MIRROR_URL" ]; then mix hex.config mirror_url "$HEX_MIRROR_URL"; fi

COPY mix.exs mix.lock ./
COPY config ./config
RUN mix deps.get --only prod
RUN mix deps.compile

COPY lib ./lib
COPY priv ./priv

RUN mix compile --warnings-as-errors \
  && mix release symphony --path /release

FROM ${RUNTIME_IMAGE} AS symphony

ARG APT_DEBIAN_MIRROR
ARG APT_SECURITY_MIRROR

ENV HOME=/home/symphony \
    CODEX_HOME=/home/symphony/.codex \
    GH_CONFIG_DIR=/home/symphony/.config/gh \
    PORT=4000 \
    SYMPHONY_SERVER_HOST=0.0.0.0 \
    SYMPHONY_LOGS_ROOT=/data/logs \
    SYMPHONY_EXECUTION_MODE=centralized

WORKDIR /app

RUN if [ -n "$APT_DEBIAN_MIRROR" ]; then \
      find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i "s|http://deb.debian.org/debian|${APT_DEBIAN_MIRROR}|g" {} +; \
    fi \
  && if [ -n "$APT_SECURITY_MIRROR" ]; then \
      find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i "s|http://deb.debian.org/debian-security|${APT_SECURITY_MIRROR}|g; s|http://security.debian.org/debian-security|${APT_SECURITY_MIRROR}|g" {} +; \
    fi

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    gh \
    git \
    libncurses6 \
    libssl3t64 \
    libstdc++6 \
    openssh-client \
    postgresql-client \
    ripgrep \
    sqlite3 \
    zlib1g \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --uid 10001 --create-home --shell /bin/bash symphony \
  && install -d -o symphony -g symphony \
    /data/logs \
    /data/workspaces \
    /home/symphony/.codex \
    /home/symphony/.config/gh \
    /home/symphony/.ssh

ENV LANG=C.UTF-8

COPY --from=codex /usr/local/bin/node /usr/local/bin/node
COPY --from=codex /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN ln -s /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex \
  && ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
  && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
COPY --from=build --chown=symphony:symphony /release /app

USER symphony

VOLUME ["/data/logs", "/data/workspaces", "/home/symphony/.codex", "/home/symphony/.config/gh"]
EXPOSE 4000

HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=6 \
  CMD curl --fail --silent http://127.0.0.1:4000/health/ready >/dev/null || exit 1

CMD ["/app/bin/symphony", "start"]

FROM ${ELIXIR_IMAGE} AS execution-worker

ARG APT_DEBIAN_MIRROR
ARG APT_SECURITY_MIRROR
ARG SYMPHONY_WORKER_IMAGE=unknown
ARG SYMPHONY_WORKER_SOURCE_REVISION=unknown

ENV HOME=/home/symphony \
    CODEX_HOME=/home/symphony/.codex \
    MIX_HOME=/worker/cache/mix \
    HEX_HOME=/worker/cache/hex \
    SYMPHONY_ROLE=worker \
    SYMPHONY_WORKER_WORKSPACE_ROOT=/worker/workspaces \
    SYMPHONY_WORKER_CACHE_ROOT=/worker/cache \
    SYMPHONY_WORKER_LOG_ROOT=/worker/logs \
    SYMPHONY_WORKER_IMAGE=${SYMPHONY_WORKER_IMAGE} \
    SYMPHONY_WORKER_SOURCE_REVISION=${SYMPHONY_WORKER_SOURCE_REVISION}

RUN if [ -n "$APT_DEBIAN_MIRROR" ]; then \
      find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i "s|http://deb.debian.org/debian|${APT_DEBIAN_MIRROR}|g" {} +; \
    fi \
  && if [ -n "$APT_SECURITY_MIRROR" ]; then \
      find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i "s|http://deb.debian.org/debian-security|${APT_SECURITY_MIRROR}|g" {} +; \
    fi \
  && apt-get update && apt-get install -y --no-install-recommends \
    bash build-essential ca-certificates curl git make openssh-client ripgrep \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --uid 10002 --create-home --shell /bin/bash symphony \
  && install -d -o symphony -g symphony /worker/workspaces /worker/cache /worker/logs /home/symphony/.codex

COPY --from=codex /usr/local/bin/node /usr/local/bin/node
COPY --from=codex /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex
COPY --from=build --chown=symphony:symphony /release /app

USER symphony
WORKDIR /worker/workspaces
VOLUME ["/worker/workspaces", "/worker/cache", "/worker/logs", "/home/symphony/.codex"]
CMD ["/app/bin/symphony", "start"]
