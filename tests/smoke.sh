#!/usr/bin/env bash
# shellcheck disable=SC2015  # "check && pass || bad": pass cannot fail, so the pattern is safe here
# Smoke test: boots the real image against a local S3 server (rclone serve s3).
# Most sections use a stub `opencode`; the last ones run the real binary and check the password gate.
#   Usage: tests/smoke.sh [image]
set -euo pipefail
IMAGE="${1:-opencode-host}"
S3_SERVER_IMAGE="${S3_SERVER_IMAGE:-docker.io/rclone/rclone:latest}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUCKET=smoke
PORT=19000
KEY=smokekey; SECRET=smokesecret123
PW=smoke-web-pw
work="$(mktemp -d)"
fail=0
pass() { echo "ok   - $*"; }
bad()  { echo "FAIL - $*"; fail=1; }
ctrs=(smoke-s3 smoke-a smoke-b smoke-c smoke-d smoke-e)
cleanup() { docker rmi -f opencode-host-smoke-ext >/dev/null 2>&1 || true; for c in "${ctrs[@]}"; do docker rm -f "$c" >/dev/null 2>&1 || true; done; rm -rf "$work"; }
for c in "${ctrs[@]}"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
trap cleanup EXIT

cat > "$work/opencode" <<'STUB'
#!/usr/bin/env bash
echo "$@" > /tmp/opencode-args
echo "stub opencode listening"
sleep infinity
STUB
chmod +x "$work/opencode"

s3env=(-e "S3_BUCKET=$BUCKET" -e S3_ENDPOINT="http://127.0.0.1:$PORT" -e "S3_ACCESS_KEY_ID=$KEY" -e "S3_SECRET_ACCESS_KEY=$SECRET" -e S3_PROVIDER=Other -e BACKUP_INTERVAL=3600 -e CRYPT_PASSWORD=smoke-crypt-pw -e CRYPT_SALT=smoke-salt -e SNAPSHOT_DELAY=3 -e "OPENCODE_SERVER_PASSWORD=$PW")
run_ctr() { # name, extra docker args...
  local name=$1; shift
  docker run -d --name "$name" --network host -v "$work/opencode":/home/node/bin/opencode:ro "${s3env[@]}" "$@" "$IMAGE" >/dev/null
}
s3list() {
  docker run --rm --network host --entrypoint rclone "$IMAGE" lsf -R ":s3:$BUCKET" --config /dev/null \
    --s3-provider Other --s3-endpoint "http://127.0.0.1:$PORT" --s3-access-key-id $KEY --s3-secret-access-key $SECRET
}

docker run -d --name smoke-s3 --network host "$S3_SERVER_IMAGE" \
  serve s3 /data --addr ":$PORT" --auth-key "$KEY,$SECRET" >/dev/null
for _ in $(seq 30); do curl -s -m 3 -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 1; done
docker run --rm --network host --entrypoint rclone "$IMAGE" mkdir ":s3:$BUCKET" --config /dev/null \
  --s3-provider Other --s3-endpoint "http://127.0.0.1:$PORT" --s3-access-key-id $KEY --s3-secret-access-key $SECRET

# --- 0. the real binary is baked in and runs offline
docker run --rm --network none --entrypoint opencode "$IMAGE" --version >/dev/null && pass "opencode runs offline" || bad "opencode does not run"

# --- 1. empty bucket boot
run_ctr smoke-a -e PORT=17861
sleep 6
[[ "$(docker exec smoke-a tmux ls 2>&1)" == server:* ]] && pass "tmux session 'server' exists" || bad "no tmux session 'server'"
args="$(docker exec smoke-a cat /tmp/opencode-args 2>/dev/null || true)"
[[ "$args" == "web --hostname 0.0.0.0 --port 17861" ]] && pass "opencode started as: $args" || bad "unexpected opencode args: $args"
docker exec smoke-a grep -q "clone-repo.sh" /home/node/.config/opencode/AGENTS.md && pass "AGENTS.md installed" || bad "AGENTS.md missing"
[[ "$(docker exec smoke-a jq -r '."$schema"' /home/node/.config/opencode/opencode.json)" == https://opencode.ai/config.json ]] && pass "opencode.json seeded" || bad "opencode.json not seeded"
grep -q '^\[server\] .*stub opencode listening' <<<"$(docker logs smoke-a 2>&1)" && pass "pane screen is shown in the container logs" || bad "pane output missing from logs"
grep -q "$PW" <<<"$(docker logs smoke-a 2>&1)" && bad "web password leaked into logs" || pass "no web password in logs"

# --- 2. SIGTERM -> final backup, fast exit
docker exec smoke-a sh -c 'mkdir -p ~/.local/share/opencode/storage ~/.config/opencode && echo "{\"fake\":\"cred\"}" > ~/.local/share/opencode/auth.json && echo sess > ~/.local/share/opencode/storage/s.json && mkdir -p ~/.config/opencode/skills/k ~/.agents/skills/k && echo cfg > ~/.config/opencode/skills/k/SKILL.md && echo agents > ~/.agents/skills/k/SKILL.md'
start=$SECONDS
docker stop -t 15 smoke-a >/dev/null
took=$((SECONDS - start))
(( took < 10 )) && pass "stopped on SIGTERM in ${took}s" || bad "slow stop (${took}s): SIGTERM likely ignored"
grep -q "final backup" <<<"$(docker logs smoke-a 2>&1)" && pass "final backup ran" || bad "final backup did not run"
listing="$(s3list)"
[[ -n "$listing" && "$listing" != *auth.json* && "$listing" != *storage* ]] && pass "encrypted objects reached the bucket (no plaintext names)" || bad "bucket empty or plaintext names: $listing"

# --- 3. second boot restores
docker rm -f smoke-a >/dev/null
run_ctr smoke-b -e PORT=17862
sleep 6
[[ "$(docker exec smoke-b cat /home/node/.local/share/opencode/auth.json 2>/dev/null)" == '{"fake":"cred"}' ]] && pass "auth.json restored on 2nd boot" || bad "auth.json not restored"
[[ "$(docker exec smoke-b stat -c %a /home/node/.local/share/opencode/auth.json)" == 600 ]] && pass "auth.json mode 600" || bad "auth.json mode not 600"
[[ "$(docker exec smoke-b cat /home/node/.local/share/opencode/storage/s.json 2>/dev/null)" == sess ]] && pass "sessions restored" || bad "sessions not restored"
[[ "$(docker exec smoke-b cat /home/node/.config/opencode/skills/k/SKILL.md 2>/dev/null)" == cfg && "$(docker exec smoke-b cat /home/node/.agents/skills/k/SKILL.md 2>/dev/null)" == agents ]] && pass "skills restored (config and agents folders)" || bad "skills not restored"
docker exec smoke-b grep -q 'skills/<name>/SKILL.md' /home/node/.config/opencode/AGENTS.md && pass "global AGENTS.md tells the agent where to install skills" || bad "skills guidance missing"
docker rm -f smoke-b >/dev/null

# --- 4. unreachable bucket still boots, without leaking secrets
run_ctr smoke-c -e PORT=17863 -e S3_ENDPOINT=http://127.0.0.1:1
sleep 6
[[ "$(docker exec smoke-c tmux ls 2>&1)" == server:* ]] && pass "boots with unreachable bucket" || bad "did not boot without bucket"
logs_c="$(docker logs smoke-c 2>&1)"
grep -q '\[restore\] ERROR' <<<"$logs_c" && pass "restore error logged" || bad "restore error not logged"
grep -qE "$SECRET|smoke-crypt-pw" <<<"$logs_c" && bad "secret leaked into logs" || pass "no secret in logs"
docker rm -f smoke-c >/dev/null

# --- 5. no password: the server is NOT started and the container says why; ALLOW_NO_PASSWORD overrides
docker run -d --name smoke-c --network host -v "$work/opencode":/home/node/bin/opencode:ro -e PORT=17866 "$IMAGE" >/dev/null
sleep 5
logs_c="$(docker logs smoke-c 2>&1)"
grep -q 'OPENCODE_SERVER_PASSWORD is not set' <<<"$logs_c" && pass "missing password is reported" || bad "missing password not reported: $logs_c"
docker exec smoke-c tmux ls >/dev/null 2>&1 && bad "server started without a password" || pass "no server without a password"
[[ "$(docker inspect -f '{{.State.Running}}' smoke-c)" == true ]] && pass "container stays up to show the message" || bad "container exited"
docker rm -f smoke-c >/dev/null
docker run -d --name smoke-c --network host -v "$work/opencode":/home/node/bin/opencode:ro -e PORT=17867 -e ALLOW_NO_PASSWORD=1 "$IMAGE" >/dev/null
sleep 5
[[ "$(docker exec smoke-c tmux ls 2>&1)" == server:* ]] && pass "ALLOW_NO_PASSWORD=1 starts the server" || bad "ALLOW_NO_PASSWORD did not start the server"
docker rm -f smoke-c >/dev/null

# --- 6. two live instances on one backup prefix: the newest wins, the older stops writing
run_ctr smoke-a -e PORT=17870
sleep 6
[[ "$(docker exec smoke-a id -u)" == 1000 ]] && pass "runs as uid 1000" || bad "not running as uid 1000"
docker exec smoke-a /home/node/bin/backup.sh >/dev/null 2>&1 && pass "first instance can back up" || bad "first instance cannot back up"
run_ctr smoke-b -e PORT=17871
sleep 6
grep -q 'WARNING another instance' <<<"$(docker logs smoke-b 2>&1)" && pass "second instance warns about the first" || bad "no lease warning"
out_a="$(docker exec smoke-a /home/node/bin/backup.sh 2>&1 || true)"
grep -q 'owns this backup prefix' <<<"$out_a" && pass "first instance refuses to back up once displaced" || bad "displaced instance still backs up: $out_a"
docker exec smoke-b /home/node/bin/backup.sh >/dev/null 2>&1 && pass "newest instance can back up" || bad "newest instance cannot back up"
docker rm -f smoke-a smoke-b >/dev/null

# --- 7. extension hooks: a failing hook and a slow hook never block boot, later hooks still run
mkdir -p "$work/hooks"
printf '#!/usr/bin/env bash\necho hook-one-fails\nexit 3\n' > "$work/hooks/10-fail.sh"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$work/hooks/20-slow.sh"
printf '#!/usr/bin/env bash\necho ran-after-failures\n' > "$work/hooks/30-ok.sh"
printf 'not executable, must be skipped\n' > "$work/hooks/40-skipped.sh"
chmod +x "$work/hooks/10-fail.sh" "$work/hooks/20-slow.sh" "$work/hooks/30-ok.sh"
run_ctr smoke-a -e PORT=17875 -e HOOK_TIMEOUT=2 -v "$work/hooks":/home/node/entrypoint.d:ro
sleep 12
logs_h="$(docker logs smoke-a 2>&1)"
grep -q 'hook 10-fail.sh failed or timed out (status 3)' <<<"$logs_h" && pass "a failing hook is logged and skipped" || bad "failing hook not reported"
grep -q 'hook 20-slow.sh failed or timed out (status 124)' <<<"$logs_h" && pass "a slow hook is stopped after HOOK_TIMEOUT" || bad "slow hook not stopped"
grep -q 'ran-after-failures' <<<"$logs_h" && pass "later hooks still run" || bad "hook after a failure did not run"
grep -q '40-skipped' <<<"$logs_h" && bad "a non-executable hook was run" || pass "non-executable files are ignored"
[[ "$(docker exec smoke-a tmux ls 2>&1)" == server:* ]] && pass "boot not blocked by hooks" || bad "hooks blocked boot"
docker rm -f smoke-a >/dev/null

# --- 8. a derived image (examples/extend) adds a tool, hooks, AGENTS.md text and opencode.json settings
if docker build -q --build-arg "BASE=$IMAGE" -t opencode-host-smoke-ext "$root/examples/extend" >/dev/null; then
  pass "examples/extend builds on the base image"
  docker run -d --name smoke-e --network host -v "$work/opencode":/home/node/bin/opencode:ro -e OPENCODE_SERVER_PASSWORD=$PW -e PORT=17873 -e GREETING=hi opencode-host-smoke-ext >/dev/null
  sleep 6
  grep -q 'hello from the example hook (GREETING=hi)' <<<"$(docker logs smoke-e 2>&1)" && pass "the derived image's boot hook ran" || bad "example hook did not run"
  docker exec smoke-e python3 --version >/dev/null 2>&1 && pass "the tool added by the derived image is installed" || bad "python3 missing in derived image"
  docker exec smoke-e grep -q "Example tool" /home/node/.config/opencode/AGENTS.md && pass "AGENTS.d fragment appended" || bad "AGENTS.d fragment missing"
  [[ "$(docker exec smoke-e jq -r .share /home/node/.config/opencode/opencode.json)" == disabled ]] && pass "settings.d fragment merged" || bad "settings.d fragment not merged"
  docker stop -t 15 smoke-e >/dev/null
  grep -q 'bye from the example hook' <<<"$(docker logs smoke-e 2>&1)" && pass "the derived image's shutdown hook ran" || bad "shutdown hook did not run"
  docker rm -f smoke-e >/dev/null
else
  bad "examples/extend failed to build"
fi

# --- 9. the REAL opencode: the web UI answers only with the password
docker run -d --name smoke-d --network host -e PORT=17880 -e OPENCODE_SERVER_PASSWORD=$PW "$IMAGE" >/dev/null
for _ in $(seq 30); do curl -s -m 3 -o /dev/null "http://127.0.0.1:17880/" && break; sleep 1; done
[[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:17880/)" == 401 ]] && pass "real opencode web refuses requests without the password" || bad "web server answered without auth"
[[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -u "opencode:wrong" http://127.0.0.1:17880/)" == 401 ]] && pass "real opencode web refuses a wrong password" || bad "web server accepted a wrong password"
[[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -u "opencode:$PW" http://127.0.0.1:17880/)" == 200 ]] && pass "real opencode web serves the UI with the password" || bad "web server did not serve the UI"
docker rm -f smoke-d >/dev/null
# --- 10. PORT: a custom value moves the real web UI; an invalid one falls back to 8080 with a warning
code() { curl -s -m 5 -o /dev/null -w '%{http_code}' -u "opencode:$PW" "$1"; }
docker run -d --name smoke-d -p 18091:18091 -e PORT=18091 -e OPENCODE_SERVER_PASSWORD=$PW "$IMAGE" >/dev/null
for _ in $(seq 30); do curl -s -m 3 -o /dev/null http://127.0.0.1:18091/ && break; sleep 1; done
[[ "$(code http://127.0.0.1:18091/)" == 200 ]] && pass "PORT=18091 moves the web UI to 18091" || bad "custom PORT not honored"
docker rm -f smoke-d >/dev/null
for bad_port in abc 0 99999; do
  docker run -d --name smoke-d -p 18092:8080 -e "PORT=$bad_port" -e OPENCODE_SERVER_PASSWORD=$PW "$IMAGE" >/dev/null
  for _ in $(seq 30); do curl -s -m 3 -o /dev/null http://127.0.0.1:18092/ && break; sleep 1; done
  grep -q "WARNING invalid PORT '$bad_port'" <<<"$(docker logs smoke-d 2>&1)" && [[ "$(code http://127.0.0.1:18092/)" == 200 ]] \
    && pass "invalid PORT=$bad_port warns and falls back to 8080" || bad "invalid PORT=$bad_port not handled"
  docker rm -f smoke-d >/dev/null
done
docker run -d --name smoke-d -p 18093:8080 -e OPENCODE_SERVER_PASSWORD=$PW "$IMAGE" >/dev/null
for _ in $(seq 30); do curl -s -m 3 -o /dev/null http://127.0.0.1:18093/ && break; sleep 1; done
[[ "$(code http://127.0.0.1:18093/)" == 200 ]] && pass "no PORT uses 8080" || bad "default port broken"
docker rm -f smoke-d >/dev/null
# --- 11. git uses the token for every command (not only clone-repo.sh), for the right hosts only
docker run -d --name smoke-a --network host -v "$work/opencode":/home/node/bin/opencode:ro -e PORT=17890 -e OPENCODE_SERVER_PASSWORD=$PW -e GITHUB_TOKEN=ghp_SMOKETOKEN -e AZDO_PAT=azdo-smoketoken "$IMAGE" >/dev/null
sleep 4
cred() { docker exec smoke-a sh -c "printf 'protocol=https\nhost=$1\n\n' | git credential fill 2>&1"; }
[[ "$(docker exec smoke-a git config --system --get credential.helper)" == /home/node/bin/git-credential-env.sh ]] && pass "git credential helper is set system-wide" || bad "credential helper not configured"
out="$(cred github.com)"; [[ "$out" == *username=x-access-token* && "$out" == *password=ghp_SMOKETOKEN* ]] && pass "git gets GITHUB_TOKEN for github.com" || bad "no token for github.com"
out="$(cred dev.azure.com)"; [[ "$out" == *password=azdo-smoketoken* ]] && pass "git gets AZDO_PAT for dev.azure.com" || bad "no token for Azure DevOps"
out="$(cred gitlab.com || true)"; [[ "$out" != *smoketoken* && "$out" != *SMOKETOKEN* ]] && pass "no token is offered to other hosts" || bad "token offered to gitlab.com"
docker exec smoke-a sh -c 'cd /tmp && rm -rf r && git init -q r && cd r && git remote add origin https://github.com/acme/x.git && ! grep -rqE "SMOKETOKEN|smoketoken" .git' && pass "token is not written to .git/config" || bad "token leaked into .git"
docker rm -f smoke-a >/dev/null
docker run -d --name smoke-a --network host -v "$work/opencode":/home/node/bin/opencode:ro -e PORT=17891 -e OPENCODE_SERVER_PASSWORD=$PW "$IMAGE" >/dev/null
sleep 4
out="$(cred github.com || true)"; [[ "$out" != *password=* ]] && pass "without a token git offers nothing and fails fast (no prompt)" || bad "credentials offered without a token"
docker rm -f smoke-a >/dev/null
(( fail == 0 )) && echo "SMOKE PASSED" || { echo "SMOKE FAILED"; exit 1; }
