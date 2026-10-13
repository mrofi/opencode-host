# Deploying

The image is a normal container with one open port: opencode's web UI on `PORT` (default 8080), protected by basic auth with `OPENCODE_SERVER_PASSWORD`. Unlike a tool that connects outbound, **this port is how you reach it**, so put HTTPS in front of it (your platform's TLS, or a reverse proxy such as Caddy or Cloudflare Tunnel); basic auth over plain HTTP sends the password in the clear.

Below, `my-opencode-host` is your image built on the base (or just use `ghcr.io/mrofi/opencode-host:latest`).

## Docker

```
docker run -d --name opencode-host --restart unless-stopped \
  -p 8080:8080 -e OPENCODE_SERVER_PASSWORD=... \
  -e S3_BUCKET=... -e S3_ENDPOINT=... -e S3_REGION=... -e S3_ACCESS_KEY_ID=... -e S3_SECRET_ACCESS_KEY=... \
  -e CRYPT_PASSWORD=... -e CRYPT_SALT=... \
  my-opencode-host
```

Use `--env-file` rather than `-e` for secrets so they stay out of your shell history. Stop it with `docker stop` (not `kill`): `SIGTERM` triggers the final backup. Give it a few seconds: `docker stop -t 30`.

A bind mount or volume on `/home/node` is an alternative to the bucket if the container always runs on the same machine, but then nothing is encrypted and nothing follows the container to another host.

## Docker Compose (example, not covered by the tests)

```yaml
services:
  opencode-host:
    image: my-opencode-host
    restart: unless-stopped
    stop_grace_period: 30s
    env_file: .env          # S3_*, CRYPT_*, GITHUB_TOKEN ... (never commit this file)
    ports: ["8080:8080"]
```

## Kubernetes and other container platforms

Run it as a single replica (never two on one `S3_PREFIX`), with secrets in the platform's secret store, a `terminationGracePeriodSeconds` of at least 30, and a TCP probe on `PORT` (an HTTP probe sees `401` without credentials), and a TLS ingress. I have not tested these platforms; the same image and variables apply.

## Hugging Face Spaces (not tested for this image)

The sibling claude-code-host image runs on a free CPU Space; this one has the same shape, but the web UI behind the Space's proxy has not been tried. Points:

- Create a **private** Space with the **Docker** SDK. It holds secrets and a live login.
- The Space repo contains a `Dockerfile` (your derived image's Dockerfile, which must start `FROM` a public image or build everything itself) and a `README.md` with this front matter:

  ```
  ---
  title: opencode host
  sdk: docker
  app_port: 8080
  ---
  ```
- Put every credential in the Space's **Secrets** and every non-secret in **Variables**. Adding or changing one restarts the Space.
- A Space restart is a **clean container**: only what is in the bucket comes back (login, history, skills, settings). Clones and files in `~/work` are gone, and sessions are not revived. Free Spaces can also sleep when idle.
- Spaces run containers as uid 1000, which this image already uses.
- Do not pass tokens in the build context or Dockerfile: they would end up in the image layers.

## After the first start

Check the logs for, in order: `starting as uid 1000`, `[lease] claimed backup prefix`, `[restore] done`, `tmux session 'server' started: opencode web on port ...`. A `NOT encrypted` warning or `cannot be decrypted` error means the encryption settings are wrong. Then open the URL and sign in (user `opencode`).

`[restore] done` only proves files came back, not that a provider login still works. If opencode exits at start, its output and exit status are in the logs and the container stays up. If you see `OPENCODE_SERVER_PASSWORD is not set`, the server was deliberately not started.
