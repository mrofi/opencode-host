# opencode host: `opencode web` in tmux with an S3-backed (encrypted) ~/.local/share/opencode, and hooks for derived images.
# opencode is MIT-licensed, so unlike Claude Code it is baked into the published image.
FROM node:22-bookworm-slim

ARG OPENCODE_VERSION=latest
# INSTALL_CODE_SERVER=1 adds code-server (VS Code in the browser at /code, needs CODE_PASSWORD at run time). Default 0.
ARG INSTALL_CODE_SERVER=0
ARG CODE_SERVER_VERSION=4.96.4

LABEL org.opencontainers.image.title="opencode-host" \
      org.opencontainers.image.description="opencode web in tmux with encrypted S3 backup of its state, and hooks for derived images" \
      org.opencontainers.image.source="https://github.com/mrofi/opencode-host"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tmux git curl ca-certificates openssh-client jq rclone procps ripgrep \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g "opencode-ai@${OPENCODE_VERSION}" && npm cache clean --force

# code-server from the official release tarball (not the curl|sh installer), unpacked under /usr/local.
RUN if [ "$INSTALL_CODE_SERVER" = "1" ]; then \
      arch="$(dpkg --print-architecture)" \
 && curl -fsSL -o /tmp/cs.tgz "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server-${CODE_SERVER_VERSION}-linux-${arch}.tar.gz" \
 && mkdir -p /usr/local/lib/code-server \
 && tar -xzf /tmp/cs.tgz -C /usr/local/lib/code-server --strip-components=1 \
 && ln -s /usr/local/lib/code-server/bin/code-server /usr/local/bin/code-server \
 && rm /tmp/cs.tgz; \
    fi

# git asks this helper for credentials for every command (clone, pull, push), not only for clone-repo.sh. It answers
# only for github.com (GITHUB_TOKEN, or GITHUB_TOKEN_<OWNER> per account/org; useHttpPath lets it see the owner) and Azure DevOps (AZDO_PAT), only when that variable is set, and says nothing
# otherwise. GIT_TERMINAL_PROMPT=0 makes a missing token fail fast instead of waiting for a password nobody can type.
RUN git config --system credential.helper /home/node/bin/git-credential-env.sh \
 && git config --system credential.https://github.com.useHttpPath true
ENV GIT_TERMINAL_PROMPT=0

# node:22 ships a non-root `node` user with uid 1000; everything runs as `node`.
USER node
ENV HOME=/home/node \
    PATH=/home/node/bin:$PATH
WORKDIR /home/node

COPY --chown=node:node scripts/ /home/node/bin/
COPY --chown=node:node config/ /home/node/config/
# Extension points for derived images (see docs/extending.md).
RUN chmod +x /home/node/bin/*.sh 2>/dev/null || true \
 && mkdir -p /home/node/entrypoint.d /home/node/shutdown.d /home/node/config/AGENTS.d /home/node/config/settings.d

EXPOSE 8080
CMD ["/home/node/bin/entrypoint.sh"]
