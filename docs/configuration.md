# Configuration

Everything is an environment variable. Unset optional ones are skipped quietly. Treat anything holding a credential as a secret in your platform (not a plain variable).

## Web server

| Name | Secret | Default | Meaning |
|---|---|---|---|
| `OPENCODE_SERVER_PASSWORD` | yes | none | **Required.** Basic-auth password of the web UI/API. Without it the server is not started (the container stays up and logs why). |
| `OPENCODE_SERVER_USERNAME` | | `opencode` | Basic-auth user name. |
| `ALLOW_NO_PASSWORD` | | unset | `1` starts the server with no password. Only for networks that already restrict access: opencode can run shell commands. |
| `PORT` | | `8080` | Port `opencode web` listens on (all interfaces); with `/code` enabled, the port of the gateway in front of it. An invalid value (not a number from 1 to 65535) logs a warning and uses 8080. With plain Docker, publish the same port: `-e PORT=9000 -p 9000:9000`. |
| `CODE_PASSWORD` | | none | Turns on VS Code in the browser at `/code` (needs an image built with `INSTALL_CODE_SERVER=1`). Without it code-server never starts. Removed from the environment of everything the entrypoint starts afterwards. |
| `CODE_URL` | | none | Public base URL of this host (for example `https://my-host.example.com`). Lets the agent print a ready link with `code-url.sh [path]` when you ask for the VS Code URL. Not secret. |
| `CODE_PORT`, `WEB_PORT` | | `8081`, `4096` | Loopback ports of code-server and, behind the gateway, `opencode web`. Not exposed; they must differ from each other and from `PORT`, else `/code` is disabled with a warning. |
| `AUTO_APPROVE` | | unset | `1` sets every opencode permission to `allow` (no prompts). See the README warning. |

## Persistence (S3-compatible bucket)

| Name | Secret | Default | Meaning |
|---|---|---|---|
| `S3_BUCKET` | | none | Setting it turns persistence on. |
| `S3_ENDPOINT` | | none | The provider's endpoint URL. |
| `S3_REGION` | | none | Region name. |
| `S3_PROVIDER` | | `Other` | rclone provider name (`AWS`, `Cloudflare`, `Minio`, `Other`, ...). |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | yes | none | Credentials for the bucket. Use a key limited to this bucket. |
| `S3_PREFIX` | | `opencode-host` | Folder inside the bucket. One per container. |
| `CRYPT_PASSWORD`, `CRYPT_SALT` | yes | none | Client-side encryption (rclone crypt). `CRYPT_PASSWORD` is required when `S3_BUCKET` is set: without it the scripts refuse to back up or restore rather than upload in plaintext. The salt is optional but recommended. Keep both outside the container. |
| `ALLOW_UNENCRYPTED` | | unset | `1` allows a bucket without encryption. Not recommended: it holds your provider logins. |
| `BACKUP_INTERVAL` | | `300` | Seconds between backups. A backup also runs on `SIGTERM`. |
| `LEASE_TTL` | | `900` | Seconds after which another instance's lease counts as stale. Keep it above `BACKUP_INTERVAL`. |
| `RCLONE_CONTIMEOUT`, `RCLONE_TIMEOUT`, `RCLONE_RETRIES`, `RCLONE_LOW_LEVEL_RETRIES` | | `10s`, `30s`, `1`, `1` | How long an unreachable bucket may delay boot. Rarely changed. |

## Git

| Name | Default | Meaning |
|---|---|---|
| `GITHUB_TOKEN` (secret) | none | Default token for github.com, used by every git command in the container (clone, pull, push). Use a read-only fine-grained token unless the agent must push. |
| `GITHUB_TOKEN_<OWNER>` (secret) | none | Token for repos of one account or org, chosen by the repo owner and tried before `GITHUB_TOKEN`. `<OWNER>` is the name in upper case with other characters as `_`: `GITHUB_TOKEN_ROKETID` for `github.com/roketid/...`, `GITHUB_TOKEN_MY_ORG` for `my-org`. |
| `AZDO_PAT` (secret) | none | Same for Azure DevOps (`dev.azure.com`, `*.visualstudio.com`). Code: Read is enough. |

Git is configured system-wide with a credential helper (`git-credential-env.sh`), so **every** git command in the container (clone, pull, push) uses the token for those hosts. The token is never put in a URL, `.git/config` or a process argument. With a read-only token, pushes are refused by the host. With a write token, anything the agent runs can push to the repos it covers: use a fine-grained token limited to the repos you need, with an expiry. Without a token, git fails fast instead of prompting.

**Several accounts or orgs.** A fine-grained GitHub token belongs to exactly one owner, so create one token per owner (each limited to the repos you need) and set one secret each, for example `GITHUB_TOKEN_MROFI`, `GITHUB_TOKEN_ROKETID` and `GITHUB_TOKEN_LIVECMS`. Git sends the repo's owner to the helper, which uses that owner's token. A repo whose owner has no `GITHUB_TOKEN_<OWNER>` falls back to `GITHUB_TOKEN`, so that token is also sent to other owners' repos on github.com (it simply fails there if it has no access). Leave `GITHUB_TOKEN` unset if you want only the per-owner tokens to apply.

## Runtime

| Name | Default | Meaning |
|---|---|---|
| `ENTRYPOINT_D` | `~/entrypoint.d` | Directory of boot hooks. |
| `SHUTDOWN_D` | `~/shutdown.d` | Directory of shutdown hooks. |
| `HOOK_TIMEOUT` | `60` | Seconds a boot hook may run. |
| `SHUTDOWN_HOOK_TIMEOUT` | `10` | Seconds a shutdown hook may run. The final backup runs after the hooks. |
| `SNAPSHOT_DELAY` | `20` | Seconds before the first snapshot of the `server` pane appears in the logs. |
| `AGENTS_D`, `SETTINGS_D`, `CONFIG_DIR` | under `~/config` | Where `AGENTS.d`, `settings.d` and the base config are read from. |

opencode's own variables (provider API keys, `OPENCODE_CONFIG`, ...) pass straight through; see opencode's docs.

## VS Code in the browser

Use the published `-code` tags (e.g. `ghcr.io/mrofi/opencode-host:latest-code`) or build with `--build-arg INSTALL_CODE_SERVER=1` (version: `CODE_SERVER_VERSION`); the arg only takes effect when building the base Dockerfile, not in an image derived `FROM` it. Run with `-e CODE_PASSWORD=...`, then open `http://host:8080/code?folder=/home/node/work/<repo>`. A bare `/code` opens `~/work`. `PORT` is then served by `scripts/gateway.js`: `/code/*` goes to code-server, everything else to `opencode web` (which moves to loopback `WEB_PORT`, so its own basic-auth password still applies). Without `CODE_PASSWORD` nothing changes. code-server's settings and extensions are in `~/.local/share/code-server` and are part of the S3 backup (caches and logs excluded).

This is a shell in the container, with the same reach as opencode: use a long password, serve it over HTTPS, and do not publish the port if you do not need `/code`. The code-server log is `~/.cache/opencode-host/code-server.log`.
