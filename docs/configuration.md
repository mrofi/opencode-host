# Configuration

Everything is an environment variable. Unset optional ones are skipped quietly. Treat anything holding a credential as a secret in your platform (not a plain variable).

## Web server

| Name | Secret | Default | Meaning |
|---|---|---|---|
| `OPENCODE_SERVER_PASSWORD` | yes | none | **Required.** Basic-auth password of the web UI/API. Without it the server is not started (the container stays up and logs why). |
| `OPENCODE_SERVER_USERNAME` | | `opencode` | Basic-auth user name. |
| `ALLOW_NO_PASSWORD` | | unset | `1` starts the server with no password. Only for networks that already restrict access: opencode can run shell commands. |
| `PORT` | | `8080` | Port `opencode web` listens on (all interfaces). |
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
| `GITHUB_TOKEN` (secret) | none | Lets `clone-repo.sh` clone private github.com repos. Use a read-only fine-grained token. |
| `AZDO_PAT` (secret) | none | Same for Azure DevOps (`dev.azure.com`, `*.visualstudio.com`). Code: Read is enough. |

Tokens are handed to git through a credential helper for those hosts only. They are not put in the clone URL, `.git/config` or process arguments.

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
