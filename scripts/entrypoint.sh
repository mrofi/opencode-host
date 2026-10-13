#!/usr/bin/env bash
# Boot sequence: restore -> seed config -> backup loop -> boot hooks -> `opencode web` in a tmux session.
# Stays alive in `wait` so a SIGTERM trap can run a final backup (an `exec`ed PID 1 would ignore it).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

workdir="$HOME/work"
port="${PORT:-8080}"
mkdir -p "$workdir"

# Identifies this boot to lease.sh (two live instances on one backup prefix would overwrite each other).
# Kept in a file as well, so a backup run by hand (docker exec) obeys the same lease.
INSTANCE_ID="$(hostname)-$$-$(date +%s)"
export INSTANCE_ID
mkdir -p "$HOME/.cache/opencode-host" && printf %s "$INSTANCE_ID" > "$HOME/.cache/opencode-host/instance-id"

echo "[entrypoint] starting as uid $(id -u)"

# Hard cap as a second guard on top of rclone's own timeouts.
timeout 90 "$here/restore.sh" || echo "[entrypoint] restore failed, continuing without restored state"
"$here/lease.sh" take || echo "[entrypoint] could not claim the backup lease (see above), continuing"
"$here/seed-config.sh" || echo "[entrypoint] seed-config failed (see above), continuing"
if [[ -n "${S3_BUCKET:-}" && -z "${CRYPT_PASSWORD:-}" && "${ALLOW_UNENCRYPTED:-}" != 1 ]]; then
  echo "[entrypoint] ERROR S3_BUCKET is set but CRYPT_PASSWORD is not: persistence disabled, no backup loop"
  sync_pid=""
elif [[ -n "${BACKUP_REMOTE:-}${S3_BUCKET:-}" ]]; then
  "$here/sync-loop.sh" &
  sync_pid=$!
else
  echo "[entrypoint] S3_BUCKET not set: persistence disabled, no backup loop"
  sync_pid=""
fi

# Extension point for derived images: run every executable *.sh in $ENTRYPOINT_D (sorted) before the web
# server starts. A hook that fails or runs too long is logged and skipped, so it can never block the server.
# A hook that starts something long-lived must background it. See docs/extending.md.
run_hooks() { # dir, timeout seconds
  local dir=$1 limit=$2 f rc
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.sh; do
    [[ -f "$f" && -x "$f" ]] || continue
    echo "[entrypoint] hook $(basename "$f")"
    timeout "$limit" "$f"; rc=$?
    (( rc == 0 )) || echo "[entrypoint] hook $(basename "$f") failed or timed out (status $rc), continuing"
  done
}
run_hooks "${ENTRYPOINT_D:-$HOME/entrypoint.d}" "${HOOK_TIMEOUT:-60}"

session=server
if [[ -z "${OPENCODE_SERVER_PASSWORD:-}" && "${ALLOW_NO_PASSWORD:-}" != 1 ]]; then
  # opencode can run shell commands, so an open server on 0.0.0.0 is remote code execution for anyone who finds it.
  echo "[entrypoint] ERROR OPENCODE_SERVER_PASSWORD is not set: the web server is NOT started (set it, or ALLOW_NO_PASSWORD=1 if the network already restricts access). The container stays up so you can see this message."
elif ! command -v opencode >/dev/null 2>&1; then
  echo "[entrypoint] ERROR the 'opencode' command is not installed in this image. The container stays up so you can see this message."
else
  # The trailing sleep keeps the pane (and its output) around if opencode exits.
  tmux new-session -d -s "$session" -c "$workdir" -x 200 -y 50 \
    "opencode web --hostname 0.0.0.0 --port $port; echo \"[$session] opencode exited with status \$?\"; sleep infinity"
  echo "[entrypoint] tmux session '$session' started: opencode web on port $port"
fi

# Many hosts give no shell, so surface the pane's screen in the logs. Snapshots only, not a stream.
snapshot_pane() {
  tmux capture-pane -p -t "$session" 2>/dev/null | sed -e 's/[[:space:]]*$//' -e '/^$/d' \
    | sed "s/^/[$session] /"
}
(
  sleep "${SNAPSHOT_DELAY:-20}"; snapshot_pane
  sleep 100; snapshot_pane
) &

shutdown() {
  echo "[entrypoint] SIGTERM received, final backup"
  if [[ -n "$sync_pid" ]]; then kill "$sync_pid" 2>/dev/null || true; fi
  # Shutdown hooks run first so anything they write into the opencode directories is part of the final backup.
  run_hooks "${SHUTDOWN_D:-$HOME/shutdown.d}" "${SHUTDOWN_HOOK_TIMEOUT:-10}"
  "$here/backup.sh" || echo "[entrypoint] final backup failed"
  "$here/lease.sh" release || true
  tmux kill-server 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

# `wait` returns when a trapped signal arrives; loop forever so the container stays up.
sleep infinity &
keeper=$!
while kill -0 "$keeper" 2>/dev/null; do
  wait "$keeper" 2>/dev/null || true
done
