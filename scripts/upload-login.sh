#!/usr/bin/env bash
# One-time (or on re-login) upload of your opencode login (auth.json) to the backup remote. Run it from your
# own machine, not inside the container. Copies one file and never deletes anything on the remote.
#   upload-login.sh <path/to/auth.json>      (usually ~/.local/share/opencode/auth.json after `opencode auth login`)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

auth="${1:?usage: upload-login.sh <auth.json>}"
[[ -f "$auth" ]] || { log upload-login "ERROR input file not found"; exit 2; }
jq empty "$auth" 2>/dev/null || { log upload-login "ERROR $auth is not valid JSON"; exit 2; }

check_crypt_access || exit 1
rclone copyto "$auth" "$BACKUP_REMOTE/data/auth.json" --quiet
log upload-login "done"
