# opencode-host

A container image that runs [opencode](https://opencode.ai) (`opencode web`) inside tmux, protected by a password, so you can open it from any browser or phone. Its login, sessions and settings can be backed up to any S3-compatible bucket with client-side encryption, so a restart brings back your setup.

It is a **base image**: you build your own Dockerfile on top of it and add the tools, config and boot logic your sessions need. It is the opencode sibling of [claude-code-host](https://github.com/mrofi/claude-code-host).

```
   browser ──► https (your proxy/platform) ──► opencode web :8080 (basic auth) in tmux "server"
   opencode data/config/state  ◄── backup every 5 min, restore on boot ──►  S3 bucket (rclone crypt)
```

Single user, one machine. It is not a multi-tenant service.

## Read this first

- **opencode runs shell commands for you, and the web UI is the way in.** The server **refuses to start** unless `OPENCODE_SERVER_PASSWORD` is set (override with `ALLOW_NO_PASSWORD=1` only when the network already restricts access). Basic auth over plain HTTP sends the password in the clear: put it behind HTTPS (your platform's, or a reverse proxy).
- **Permissions.** opencode's defaults allow most tools and ask for `external_directory` and `doom_loop`. You answer prompts in the web UI. `AUTO_APPROVE=1` allows everything with no prompts: then anything the container can reach, a prompt-injected repo or web page could use. Give the container only credentials you are willing to lose.
- **Your provider keys are in the bucket** (encrypted) once you log in or add keys. Treat the bucket and `CRYPT_PASSWORD` accordingly.
- opencode is MIT-licensed, so this image includes it (installed from npm as `opencode-ai`, `OPENCODE_VERSION` build arg).

## Quick start

```
docker run -d --name opencode-host -p 8080:8080 \
  -e OPENCODE_SERVER_PASSWORD='choose-a-long-password' \
  ghcr.io/mrofi/opencode-host:latest
```

Open `http://localhost:8080` (user `opencode`, your password). To use another port set `PORT` and publish the same one: `-e PORT=9000 -p 9000:9000`. Add a provider in the UI (or set the provider's API key variable, for example `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`, which opencode reads). Without a bucket nothing is persisted, but it works.

### Opening a project and starting a session in the web UI

Checked in a browser against this image (opencode 1.19.0):

1. The home page lists your **Projects** in the left sidebar. Click **Add project** (the folder icon next to "Projects" does the same).
2. In the "Open project" box, type the **full path** and wait a moment: `/home/node/work/` lists the folders under `~/work`. Typing just a folder name finds nothing. Pick the folder (for example one made with `clone-repo.sh <name> --repo <url>`, which lands in `/home/node/work/<name>`).
3. The project appears in the sidebar. Click it (or **New session**) to get a new-session page with a prompt box. Pick a model or connect a provider (Settings, or the "Connect to 75+ providers" link), type a prompt, and the session is created.
4. Later sessions of a project are listed on its page, and every session survives restarts if the backup is on.

Not covered by that check: sending a prompt (it needs a provider login or key, which I did not use).

To look at or use the terminal UI instead: `docker exec -it opencode-host opencode attach http://localhost:8080 -p <password>` (or `tmux attach -t server` to see the server's output).

## Persistence (optional, recommended)

Set these and the container restores opencode's data (`auth.json`, sessions), config and state on boot, and backs them up every 5 minutes and on `SIGTERM`:

| Variable | Meaning |
|---|---|
| `S3_BUCKET`, `S3_ENDPOINT`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_PROVIDER` | Any S3-compatible bucket (AWS, Cloudflare R2, MinIO, IDrive e2, ...). |
| `CRYPT_PASSWORD`, `CRYPT_SALT` | **Required** when `S3_BUCKET` is set. Everything is encrypted client-side (rclone crypt). Keep a copy outside the container: lose them and the backup cannot be read. |
| `S3_PREFIX` | Folder in the bucket (default `opencode-host`). Use a different one per container. |

Never run two containers on one prefix: the newest one wins and the older one stops backing up, with a warning in its logs. To seed a login from your own machine instead of logging in inside the container, run `opencode auth login` locally, then `scripts/upload-login.sh ~/.local/share/opencode/auth.json` with the `S3_*`/`CRYPT_*` variables set. Every other setting: [docs/configuration.md](docs/configuration.md).

## Extend it

Derived images add four kinds of things without editing any base script:

| Add | Where | Effect |
|---|---|---|
| Boot logic | `/home/node/entrypoint.d/*.sh` | Run in name order before the web server starts. A failing or slow hook is logged and skipped. |
| Shutdown logic | `/home/node/shutdown.d/*.sh` | Run on `SIGTERM`, before the final backup. |
| Instructions for the agent | `/home/node/config/AGENTS.d/*.md` | Appended to the `AGENTS.md` opencode reads in `~/work` (tell it about your tools). |
| opencode settings | `/home/node/config/settings.d/*.json` | Merged into `~/.config/opencode/opencode.json`. |

Plus any packages or tools you install. A complete, tested example is in [`examples/extend`](examples/extend); the guide is [docs/extending.md](docs/extending.md).

## Deploy

It is a normal container: anything that can run one works. See [docs/deploy.md](docs/deploy.md).

## What is in the image

Node 22 (Debian bookworm), opencode, tmux, git, ripgrep, curl, jq, rclone, openssh-client, a non-root `node` user (uid 1000), and the scripts in `scripts/`:

| Script | Purpose |
|---|---|
| `entrypoint.sh` | Boot: restore, seed config, backup loop, hooks, then `opencode web` in the tmux `server` session. |
| `clone-repo.sh` | Clone a github.com or Azure DevOps repo into `~/work/<name>` so it shows up as a project. |
| `backup.sh`, `restore.sh`, `upload-login.sh`, `lease.sh` | Persistence. |
| `git-credential-env.sh` | Serves `GITHUB_TOKEN` / `AZDO_PAT` to git for those hosts only. |

## Develop

```
bats tests/*.bats                               # unit tests (needs bats, rclone, tmux, jq, git, socat)
shellcheck -x -P SCRIPTDIR scripts/*.sh tests/*.sh
docker build -t opencode-host .
tests/smoke.sh opencode-host                    # boots the image against a local S3 server (rclone serve s3); also runs the real opencode
tests/layer-scan.sh opencode-host               # looks for secrets in every image layer
```

The smoke test uses a local S3 server, which is more forgiving than some real providers. After changing how files are written to the bucket, also try the scripts once against your real bucket with encryption on, in a throwaway `S3_PREFIX`.

## Not tested

The arm64 image, the Docker Compose example, running behind a TLS proxy, and the TUI `attach` path from inside the container. The web server, the password gate, backup/restore and the hooks are covered by the tests.

## License

MIT, see [LICENSE](LICENSE). opencode is licensed separately by its authors.
