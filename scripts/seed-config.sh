#!/usr/bin/env bash
# Install image-managed config: the global rules file ~/.config/opencode/AGENTS.md (always refreshed; opencode reads it
# in every session, whatever the project) and
# the base keys of ~/.config/opencode/opencode.json (merged, keeping everything else).
# Derived images extend both without touching this script:
#   config/AGENTS.d/*.md     appended to the global AGENTS.md, in name order
#   config/settings.d/*.json merged into opencode.json, in name order (later files win)
# AUTO_APPROVE=1 additionally sets every permission to "allow" (opencode's default already allows most tools;
# this also covers external_directory and doom_loop, which default to "ask").
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="${CONFIG_DIR:-$here/../config}"
ocdir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

mkdir -p "$HOME/work" "$ocdir"
# Earlier versions wrote the rules to ~/work/AGENTS.md; drop that copy (only if it is ours) so they are not read twice.
if [[ -f "$HOME/work/AGENTS.md" ]] && head -1 "$HOME/work/AGENTS.md" | grep -qx '# opencode host'; then rm -f "$HOME/work/AGENTS.md"; fi
cp "$config/AGENTS.md" "$ocdir/AGENTS.md"
for f in "${AGENTS_D:-$config/AGENTS.d}"/*.md; do
  [[ -f "$f" ]] || continue
  { echo; cat "$f"; } >> "$ocdir/AGENTS.md"
done

settings="$ocdir/opencode.json"
[[ -s "$settings" ]] || echo '{}' > "$settings"
if ! jq empty "$settings" 2>/dev/null; then
  echo "[seed-config] ERROR $settings is not valid JSON; leaving it untouched" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
fragments=("$config/opencode.json")
for f in "${SETTINGS_D:-$config/settings.d}"/*.json; do [[ -f "$f" ]] && fragments+=("$f"); done
if [[ "${AUTO_APPROVE:-}" == 1 ]]; then
  auto="$(mktemp)"; trap 'rm -f "$tmp" "$auto"' EXIT
  echo '{"permission":{"edit":"allow","bash":"allow","webfetch":"allow","external_directory":"allow","doom_loop":"allow"}}' > "$auto"
  fragments+=("$auto")
fi
jq -s 'reduce .[] as $x ({}; . * $x)' "$settings" "${fragments[@]}" > "$tmp"
mv "$tmp" "$settings"
