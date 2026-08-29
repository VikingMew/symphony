# syntax=docker/dockerfile:1

ARG ELIXIR_IMAGE=elixir:1.19.5-otp-28-slim
ARG NODE_IMAGE=node:22-bookworm-slim
ARG CODEX_VERSION=0.150.1
ARG MISE_VERSION=2025.8.16

FROM ${ELIXIR_IMAGE} AS toolchain

ARG APT_DEBIAN_MIRROR
ARG APT_SECURITY_MIRROR
ARG MISE_VERSION
ARG TARGETARCH

ENV MISE_DATA_DIR=/opt/mise \
    PATH=/opt/mise/shims:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

RUN if [ -n "$APT_DEBIAN_MIRROR" ]; then \
      find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i "s|http://deb.debian.org/debian|${APT_DEBIAN_MIRROR}|g" {} +; \
    fi \
  && if [ -n "$APT_SECURITY_MIRROR" ]; then \
      find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i "s|http://deb.debian.org/debian-security|${APT_SECURITY_MIRROR}|g; s|http://security.debian.org/debian-security|${APT_SECURITY_MIRROR}|g" {} +; \
    fi \
  && apt-get update && apt-get install -y --no-install-recommends \
    bash build-essential ca-certificates curl git make openssh-client ripgrep \
  && rm -rf /var/lib/apt/lists/* \
  && case "$TARGETARCH" in amd64) mise_arch=x64 ;; arm64) mise_arch=arm64 ;; *) exit 1 ;; esac \
  && curl --fail --location --silent --show-error \
    "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-${mise_arch}.tar.gz" \
    | tar --extract --gzip --directory /usr/local/bin --strip-components=2 "mise-v${MISE_VERSION}-linux-${mise_arch}/bin/mise" \
  && mise link erlang@28 /usr/local \
  && mise link elixir@1.19.5-otp-28 /usr/local \
  && mise reshim

FROM ${NODE_IMAGE} AS codex

ARG CODEX_VERSION
ARG NPM_REGISTRY

RUN if [ -n "$NPM_REGISTRY" ]; then npm config set registry "$NPM_REGISTRY"; fi \
  && npm install --global "@openai/codex@${CODEX_VERSION}"

FROM toolchain AS worker

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
  && install -d -o symphony -g symphony /workspace/.cache \
  && printf '%s\n' \
    'PasswordAuthentication no' \
    'PermitRootLogin no' \
    'PubkeyAuthentication yes' \
    'StrictModes no' \
    'AuthorizedKeysFile .ssh/authorized_keys' \
    'AcceptEnv *' \
    > /etc/ssh/sshd_config.d/symphony-worker.conf

RUN chown symphony:symphony /workspace

ENV HOME=/home/symphony \
    MIX_HOME=/workspace/.cache/mix \
    HEX_HOME=/workspace/.cache/hex \
    MISE_CACHE_DIR=/workspace/.cache/mise

COPY --from=codex /usr/local/bin/node /usr/local/bin/node
COPY --from=codex /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN ln -s /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex \
  && ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
  && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]

FROM toolchain AS build

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

FROM toolchain AS symphony

ARG APT_DEBIAN_MIRROR
ARG APT_SECURITY_MIRROR

ENV HOME=/home/symphony \
    CODEX_HOME=/home/symphony/.codex \
    GH_CONFIG_DIR=/home/symphony/.config/gh \
    MIX_HOME=/data/workspaces/.cache/mix \
    HEX_HOME=/data/workspaces/.cache/hex \
    MISE_CACHE_DIR=/data/workspaces/.cache/mise \
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
    openssh-client \
    postgresql-client \
    ripgrep \
    sqlite3 \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --uid 10001 --create-home --shell /bin/bash symphony \
  && git config --system credential.https://github.com.helper '!gh auth git-credential' \
  && git config --system url.https://github.com/.insteadOf 'git@github.com:' \
  && install -d -o symphony -g symphony \
    /data/logs \
    /data/workspaces \
    /data/workspaces/.cache \
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

FROM toolchain AS execution-worker

ARG APT_DEBIAN_MIRROR
ARG APT_SECURITY_MIRROR
ARG SYMPHONY_WORKER_IMAGE=unknown
ARG SYMPHONY_WORKER_SOURCE_REVISION=unknown

ENV HOME=/home/symphony \
    CODEX_HOME=/home/symphony/.codex \
    MIX_HOME=/worker/cache/mix \
    HEX_HOME=/worker/cache/hex \
    MISE_CACHE_DIR=/worker/cache/mise \
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
