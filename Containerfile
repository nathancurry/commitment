FROM docker.io/library/node:22-bookworm

ARG OPENCODE_VERSION=1.18.30

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates curl git jq python3 ripgrep \
    && npm install --global "opencode-ai@${OPENCODE_VERSION}" \
    && opencode --version \
    && rm -rf /var/lib/apt/lists/* /root/.npm

WORKDIR /workspace/commitment

ENV HOME=/home/commitment \
    XDG_CONFIG_HOME=/home/commitment/.config \
    XDG_DATA_HOME=/home/commitment/.local/share \
    OPENCODE_ENABLE_EXA=1

CMD ["opencode", "--version"]
