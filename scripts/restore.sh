#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

check_crypt_access || exit 1

# --extra: the directories of BACKUP_EXTRA_DIRS, run on its own so a large one cannot hold up the rest.
if [[ "${1:-}" == --extra ]]; then
  rm -rf "$RESTORED_MARKS"; mkdir -p "$RESTORED_MARKS"
  (( ${#EXTRA_NAMES[@]} )) || exit 0
  if ! top="$(rclone lsf "$BACKUP_REMOTE" 2>/dev/null)"; then
    log restore "ERROR cannot reach backup remote: BACKUP_EXTRA_DIRS not restored, and not backed up until the next boot"
    exit 1
  fi
  saved=""
  grep -qx 'extra/' <<<"$top" && saved="$(rclone lsf "$BACKUP_REMOTE/extra" 2>/dev/null || true)"
  failed=0
  for n in "${EXTRA_NAMES[@]}"; do
    d="${EXTRA_DIRS[$n]}"
    if grep -qx "$n/" <<<"$saved"; then
      mkdir -p "$d"
      if ! rclone copy "$BACKUP_REMOTE/extra/$n" "$d" --quiet 2>&1; then
        log restore "ERROR $n could not be restored, and is not backed up until the next boot"
        failed=1
        continue
      fi
      log restore "$n restored into $d"
    fi
    touch "$RESTORED_MARKS/$n"
  done
  exit "$failed"
fi

# stdout only: rclone writes notices to stderr, which must not count as "remote has files".
if ! listing="$(rclone lsf "$BACKUP_REMOTE" 2>/dev/null)"; then
  log restore "ERROR cannot reach backup remote (continuing without restore)"
  exit 1
fi
# The lease object (see lease.sh) is not backup content.
listing="$(grep -vx 'lease' <<<"$listing" || true)"
if [[ -z "$listing" ]]; then
  log restore "nothing to restore (empty remote)"
  exit 0
fi

for n in "${OC_NAMES[@]}"; do
  # A part that was never backed up (for example state on a young instance) is simply absent: skip it.
  grep -qx "$n/" <<<"$listing" || continue
  d="$(oc_dir "$n")"
  mkdir -p "$d"
  rclone copy "$BACKUP_REMOTE/$n" "$d" --quiet
  chmod 700 "$d"
done
[[ -f "$(oc_dir data)/auth.json" ]] && chmod 600 "$(oc_dir data)/auth.json"
log restore "done"
