# opencode host: `opencode web` in tmux with an S3-backed (encrypted) ~/.local/share/opencode, and hooks for derived images.
# opencode is MIT-licensed, so unlike Claude Code it is baked into the published image.
FROM node:22-bookworm-slim

ARG OPENCODE_VERSION=latest

LABEL org.opencontainers.image.title="opencode-host" \
      org.opencontainers.image.description="opencode web in tmux with encrypted S3 backup of its state, and hooks for derived images" \
      org.opencontainers.image.source="https://github.com/mrofi/opencode-host"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tmux git curl ca-certificates openssh-client jq rclone procps ripgrep \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g "opencode-ai@${OPENCODE_VERSION}" && npm cache clean --force

# git asks this helper for credentials for every command (clone, pull, push), not only for clone-repo.sh. It answers
# only for github.com (GITHUB_TOKEN) and Azure DevOps (AZDO_PAT), only when that variable is set, and says nothing
# otherwise. GIT_TERMINAL_PROMPT=0 makes a missing token fail fast instead of waiting for a password nobody can type.
RUN git config --system credential.helper /home/node/bin/git-credential-env.sh
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
