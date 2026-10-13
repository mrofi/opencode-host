# How it works

## Boot

`entrypoint.sh`, in order:

1. Restores opencode's data, config and state from the bucket (hard limit 90 s; an unreachable bucket is logged and boot continues).
2. Claims the backup prefix (`lease.sh`), then writes the global rules file `~/.config/opencode/AGENTS.md` and merges the base keys into `~/.config/opencode/opencode.json`.
3. Starts the backup loop (only if `S3_BUCKET` is set and encryption is configured).
4. Runs your boot hooks (`entrypoint.d`).
5. Starts a tmux session named `server` running `opencode web --hostname 0.0.0.0 --port $PORT` in `~/work`, **unless** `OPENCODE_SERVER_PASSWORD` is unset (then it logs an error and stays up) or `opencode` is missing.
6. Prints snapshots of the pane to the logs (at +20 s and +120 s), because many hosts give you no shell. Then it waits; on `SIGTERM` it runs shutdown hooks, a final backup and stops cleanly.

The web UI is opencode's own: it serves HTTP on `PORT`, with basic auth when the password is set. There is no separate health endpoint: an unauthenticated request gets `401`, which still proves the server is up (use a TCP or "expect 401" probe).

## Projects

opencode works per directory. `clone-repo.sh <name> --repo <url>` clones into `~/work/<name>`; open that directory as a project in the web UI (Add project, then type the full path such as `/home/node/work/<name>`; see the README). Names are lowercase `a-z0-9-` (max 31); URLs must be https on github.com or Azure DevOps, without credentials. opencode itself manages multiple sessions, so this image has no session-spawning scripts.

## Persistence

opencode keeps its state in three XDG directories. Each is backed up under its own name in `<prefix>/`:

| Local | Backed up as | Holds |
|---|---|---|
| `~/.local/share/opencode` | `data/` | `auth.json` (provider logins), sessions and their storage |
| `~/.config/opencode` | `config/` | `opencode.json`, agents, commands, plugins |
| `~/.local/state/opencode` | `state/` | prompt history, recent models |
| `~/.claude/skills` | `claude-skills/` | skills in the Claude-compatible folder, if an agent installs there |
| `~/.agents/skills` | `agents-skills/` | skills in the agent-compatible folder |

Skills: opencode reads them from `~/.config/opencode/skills/<name>/SKILL.md` and the two folders above, plus `.opencode/`, `.claude/` and `.agents/` folders inside a repo. The first three are backed up; skills inside a repo come back only if committed. The image's `AGENTS.md` asks the agent to install skills into `~/.config/opencode/skills/`.

Excluded (top level of each): `log/`, `bin/`, `snapshot/`, `node_modules/`, and `*.lock`. Not backed up: `~/work` (clone and push), anything else, and your platform's secrets.

When: every `BACKUP_INTERVAL` (300 s) and on `SIGTERM`. A hard kill loses up to one interval. `backup.sh` forces one now.

Encryption: rclone crypt (file contents and names). A wrong password is reported as an error (`cannot be decrypted`), never as an empty bucket, and a half-configured container (bucket but no password) refuses to touch the bucket.

### Two containers on one prefix

`lease.sh` keeps a small lease file next to the backup. The newest container to boot takes it (with a warning if the previous owner was recent). The older one then refuses to back up (`owns this backup prefix`). A crashed container's lease expires after `LEASE_TTL`. If you want two containers, give each its own `S3_PREFIX`.

## Login

opencode stores provider logins in `~/.local/share/opencode/auth.json`. Either log in through the web UI (it is then in the next backup), set the provider's API key variable, or upload an existing `auth.json` from your machine with `scripts/upload-login.sh`. Note that a login copied to a container is a second holder of the same credentials: revoke it at the provider if the container is ever compromised.

## Failure behavior

| Situation | Result |
|---|---|
| No `OPENCODE_SERVER_PASSWORD` | Server not started; clear error in the logs; container stays up. |
| Bucket unreachable at boot | Logged (`[restore] ERROR`); boot continues without restored state. |
| Wrong `CRYPT_PASSWORD` | Restore and backup refuse with `cannot be decrypted`; nothing is overwritten. |
| `S3_BUCKET` set, no `CRYPT_PASSWORD` | Persistence disabled with an error; nothing uploaded. |
| `opencode` exits | The tmux pane stays up with its output and exit status; the container keeps running. |
| A boot hook fails or hangs | Logged and skipped after `HOOK_TIMEOUT`; the server still starts. |
| Two containers, one prefix | The older stops backing up, with an error. |

## Security notes

- The web UI can run commands in the container. Use a strong password and HTTPS in front of it.
- Secrets live in the container's environment and are visible to the agent. `AGENTS.md` tells it not to print them, but that is an instruction, not a control.
- Do not put credentials in the image: `tests/layer-scan.sh` checks every layer, including deleted files, for secret patterns, and can search for the exact values of your real secrets.
- The bucket holds your provider logins (encrypted). Use a bucket key limited to that bucket, and keep `CRYPT_PASSWORD` and `CRYPT_SALT` in a password manager.
- The container runs as uid 1000, not root.
