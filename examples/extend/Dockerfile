# Example: your own image on top of the opencode-host base.
#   docker build -t my-opencode-host examples/extend
# Replace the base with the image you pulled or built (see the README).
ARG BASE=ghcr.io/mrofi/opencode-host:latest
FROM ${BASE}

# Add whatever tools your sessions need. System packages need root.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*
USER node

# Boot hooks run before the web server starts; shutdown hooks run before the final backup.
COPY --chown=node:node entrypoint.d/ /home/node/entrypoint.d/
COPY --chown=node:node shutdown.d/   /home/node/shutdown.d/
# Tell the agent about your tools (appended to the global ~/.config/opencode/AGENTS.md) and add opencode.json settings.
COPY --chown=node:node AGENTS.d/     /home/node/config/AGENTS.d/
COPY --chown=node:node settings.d/   /home/node/config/settings.d/
