# syntax=docker/dockerfile:1

ARG ELIXIR_IMAGE=elixir:1.19-otp-28-slim
ARG NODE_IMAGE=node:20-bookworm-slim

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
COPY --from=codex /usr/local/bin/npm /usr/local/bin/npm
COPY --from=codex /usr/local/bin/npx /usr/local/bin/npx
COPY --from=codex /usr/local/bin/codex /usr/local/bin/codex
COPY --from=codex /usr/local/lib/node_modules /usr/local/lib/node_modules

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
RUN mix compile
RUN mix build

FROM ${ELIXIR_IMAGE} AS app-runtime

ARG APT_DEBIAN_MIRROR
ARG APT_SECURITY_MIRROR

ENV MIX_ENV=prod \
    PORT=4000 \
    HOME=/home/symphony \
    SYMPHONY_DATABASE_PATH=/data/symphony.db \
    SYMPHONY_EXECUTION_MODE=worker

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
    git \
    openssh-client \
    ripgrep \
    sqlite3 \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --create-home --shell /bin/bash symphony \
  && install -d -o symphony -g symphony /data /data/logs /data/workspaces /external /home/symphony/.codex

COPY --from=build --chown=symphony:symphony /app /app

USER symphony

VOLUME ["/data"]
EXPOSE 4000

CMD ["sh", "-c", "mix ecto.migrate && exec ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --logs-root /data/logs --port ${PORT}"]

FROM app-runtime AS dashboard-internal-db

ENV SYMPHONY_DATABASE_PATH=/data/symphony.db \
    SYMPHONY_EXECUTION_MODE=worker

FROM app-runtime AS dashboard-external-db

ENV SYMPHONY_DATABASE_PATH=/external/symphony.db \
    SYMPHONY_EXECUTION_MODE=worker

VOLUME ["/external"]

FROM app-runtime AS all-in-one

ENV SYMPHONY_DATABASE_PATH=/data/symphony.db \
    SYMPHONY_EXECUTION_MODE=centralized

USER root

COPY --from=codex /usr/local/bin/node /usr/local/bin/node
COPY --from=codex /usr/local/bin/npm /usr/local/bin/npm
COPY --from=codex /usr/local/bin/npx /usr/local/bin/npx
COPY --from=codex /usr/local/bin/codex /usr/local/bin/codex
COPY --from=codex /usr/local/lib/node_modules /usr/local/lib/node_modules

USER symphony

VOLUME ["/data", "/home/symphony/.codex"]
EXPOSE 4000
