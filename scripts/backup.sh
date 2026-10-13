#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

exec 9>"${BACKUP_LOCK:-${TMPDIR:-/tmp}/opencode-backup.lock}"
if ! flock -n 9; then
  log backup "already running, skipping"
  exit 0
fi

check_crypt_access || exit 1
"$here/lease.sh" check || exit 1

did=0
for n in "${OC_NAMES[@]}"; do
  d="$(oc_dir "$n")"
  [[ -d "$d" ]] || continue
  did=1
  if ! rclone sync "$d" "$BACKUP_REMOTE/$n" "${BACKUP_EXCLUDES[@]}" --quiet 2>&1; then
    log backup "ERROR sync of $n failed"
    exit 1
  fi
done
(( did )) || { log backup "no opencode directories yet, nothing to back up"; exit 0; }
log backup "done"
