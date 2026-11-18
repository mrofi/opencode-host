# Extending the image

Build your own image `FROM` the base and add files. You never edit the base scripts, so upgrading the base is a version bump.

```dockerfile
FROM ghcr.io/mrofi/opencode-host:latest

USER root
RUN apt-get update && apt-get install -y --no-install-recommends ripgrep && rm -rf /var/lib/apt/lists/*
USER node

COPY --chown=node:node entrypoint.d/ /home/node/entrypoint.d/
COPY --chown=node:node shutdown.d/   /home/node/shutdown.d/
COPY --chown=node:node AGENTS.d/     /home/node/config/AGENTS.d/
COPY --chown=node:node settings.d/   /home/node/config/settings.d/
```

Keep the final `USER node`: the base runs as uid 1000 and its state directories belong to that user.

## Boot hooks: `/home/node/entrypoint.d/*.sh`

- Executable files ending in `.sh`, run **in name order** (`10-…`, `20-…`) as the `node` user.
- They run after opencode's data, config and state are restored and the backup loop started, **before** the web server starts. Anything they need from the backup is there.
- Each runs with the container's environment (so secrets are available) and is stopped after `HOOK_TIMEOUT` seconds (default 60).
- A hook that exits non-zero or times out is logged (`hook NAME failed or timed out (status N)`) and skipped. Later hooks still run, and the web server still starts. A hook can therefore never keep the server from starting, but check the logs: a silent failure is still a failure.
- A hook that starts something long-lived (a tunnel, a daemon) must background it: `mytool &`. Otherwise it blocks boot until the timeout.
- Not executable, or not `.sh`: ignored.
- Never print secrets from a hook: stdout goes to the container logs.

```bash
#!/usr/bin/env bash
# entrypoint.d/10-vpn.sh
[[ -n "${VPN_TOKEN:-}" ]] || { echo "vpn: no VPN_TOKEN, skipping"; exit 0; }
my-vpn-client --token-env VPN_TOKEN &
```

## Shutdown hooks: `/home/node/shutdown.d/*.sh`

Run on `SIGTERM` in name order, each limited to `SHUTDOWN_HOOK_TIMEOUT` seconds (default 10), **before** the final backup, so files they write into opencode's directories (`~/.local/share/opencode`, `~/.config/opencode`) are saved. Keep them short: platforms stop a container after a short grace period.

## Telling the sessions about your tools: `config/AGENTS.d/*.md`

At every boot the global rules file `~/.config/opencode/AGENTS.md` is rebuilt from the base file plus your fragments (name order). opencode reads it in every session, whatever the project. The file is owned by the image (edits to it are overwritten at boot): put your own rules in a fragment, or in a repo's `AGENTS.md`. Say what the tool is, how to call it, and what to avoid:

```markdown
## Database access
Use `dbq <sql>` for read-only queries. Never run `dbq` with INSERT, UPDATE or DELETE unless the owner asks.
```

Sessions run without permission prompts, so these instructions are guidance, not enforcement. Enforce limits with the credentials you hand the container.

## opencode settings: `config/settings.d/*.json`

Each file is merged into `~/.config/opencode/opencode.json` in name order (later files win; objects merge key by key). The base's own required key (`skipDangerousModePermissionPrompt`) is applied first, and an existing `settings.json` keeps its other keys. An invalid JSON fragment makes `seed-config.sh` fail loudly and leaves `settings.json` untouched.

## Backing up your own directories: `BACKUP_EXTRA_DIRS`

When persistence is on, a derived image can add its own directories to the backup:

```dockerfile
ENV BACKUP_EXTRA_DIRS="mytool=/home/node/.local/share/mytool other=/home/node/data"
```

- Each directory goes to `extra/<name>` in the bucket, encrypted like the rest. It is copied as it is:
  none of the excludes for opencode's own directories (`bin/`, `log/`, `*.lock`, ...) apply.
- At boot it is restored after opencode's directories, with its own time limit (`EXTRA_RESTORE_TIMEOUT`,
  default 600 s), and before the boot hooks run, so a hook finds it in place.
- If its restore fails or times out, it is **not backed up** until the next boot, so a partial copy never
  replaces the backup. The logs say so.
- The backup keeps file contents only: file modes (the executable bit) and symbolic links are not kept.
  Put what needs them in an archive, or restore them in a boot hook.
- Names: lowercase letters, digits, `_` and `-`. Paths: absolute. An entry that is not valid is skipped
  with a warning.

## Checking your image

- `docker logs <container>` shows `[entrypoint] hook NAME` for every hook it ran.
- The base repo's `tests/smoke.sh` shows how to test hooks, including a failing and a slow one.
- `examples/extend` is a small, tested derived image that uses all four extension points.
