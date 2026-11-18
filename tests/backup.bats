#!/usr/bin/env bats
# backup.sh / restore.sh against a local directory standing in for the bucket.

setup() {
  unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME
  export HOME="$BATS_TEST_TMPDIR/home"
  export BACKUP_REMOTE="$BATS_TEST_TMPDIR/remote"
  mkdir -p "$HOME" "$BACKUP_REMOTE"
  export PATH="$BATS_TEST_DIRNAME/../scripts:$PATH"
  D="$HOME/.local/share/opencode"; C="$HOME/.config/opencode"; S="$HOME/.local/state/opencode"
}

@test "backup copies data, config and state, and skips logs, binaries and snapshots" {
  mkdir -p "$D/log" "$D/bin" "$D/snapshot/x" "$D/storage/session" "$C" "$S"
  echo '{"openai":{"key":"k"}}' > "$D/auth.json"
  echo s > "$D/storage/session/a.json"
  echo big > "$D/bin/tool"; echo l > "$D/log/x.log"; echo g > "$D/snapshot/x/obj"
  echo '{}' > "$C/opencode.json"; echo h > "$S/prompt-history"
  run backup.sh
  [ "$status" -eq 0 ]
  [ -f "$BACKUP_REMOTE/data/auth.json" ]
  [ -f "$BACKUP_REMOTE/data/storage/session/a.json" ]
  [ -f "$BACKUP_REMOTE/config/opencode.json" ]
  [ -f "$BACKUP_REMOTE/state/prompt-history" ]
  [ ! -e "$BACKUP_REMOTE/data/bin/tool" ]
  [ ! -e "$BACKUP_REMOTE/data/log/x.log" ]
  [ ! -e "$BACKUP_REMOTE/data/snapshot" ]
}

@test "backup with nothing to back up is not an error" {
  run backup.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to back up"* ]]
}

@test "restore brings everything back and locks down auth.json" {
  mkdir -p "$BACKUP_REMOTE/data" "$BACKUP_REMOTE/config"
  echo '{"a":1}' > "$BACKUP_REMOTE/data/auth.json"; chmod 644 "$BACKUP_REMOTE/data/auth.json"
  echo '{"theme":"x"}' > "$BACKUP_REMOTE/config/opencode.json"
  run restore.sh
  [ "$status" -eq 0 ]
  [ -f "$D/auth.json" ]
  [ "$(stat -c %a "$D/auth.json")" = "600" ]
  [ "$(stat -c %a "$D")" = "700" ]
  [ "$(jq -r .theme "$C/opencode.json")" = "x" ]
}

@test "restore from an empty remote does nothing" {
  run restore.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to restore"* ]]
}

@test "backup then restore round-trips into a fresh home" {
  mkdir -p "$D"; echo '{"k":"v"}' > "$D/auth.json"
  backup.sh
  export HOME="$BATS_TEST_TMPDIR/home2"; mkdir -p "$HOME"
  run restore.sh
  [ "$(cat "$HOME/.local/share/opencode/auth.json")" = '{"k":"v"}' ]
}

@test "S3_BUCKET without CRYPT_PASSWORD refuses to run (no plaintext logins in a bucket)" {
  mkdir -p "$D"; echo '{}' > "$D/auth.json"
  unset BACKUP_REMOTE
  S3_BUCKET=b run backup.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRYPT_PASSWORD is required"* ]]
}

@test "crypt: object names and content are not readable in the bucket, and a wrong password is refused" {
  command -v rclone >/dev/null || skip "rclone not installed"
  mkdir -p "$D"; echo 'TOP-SECRET-TOKEN' > "$D/auth.json"
  export CRYPT_PASSWORD=pw1 CRYPT_SALT=salt1
  run backup.sh
  [ "$status" -eq 0 ]
  run grep -r "TOP-SECRET-TOKEN" "$BACKUP_REMOTE"
  [ "$status" -ne 0 ]
  [ -z "$(find "$BACKUP_REMOTE" -name 'auth.json')" ]
  export CRYPT_PASSWORD=wrong
  run restore.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be decrypted"* ]]
}

@test "upload-login copies only auth.json and rejects bad input" {
  echo '{"anthropic":{"type":"oauth"}}' > "$BATS_TEST_TMPDIR/auth.json"
  run upload-login.sh "$BATS_TEST_TMPDIR/auth.json"
  [ "$status" -eq 0 ]
  [ -f "$BACKUP_REMOTE/data/auth.json" ]
  echo 'not json' > "$BATS_TEST_TMPDIR/bad.json"
  run upload-login.sh "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
  run upload-login.sh "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 2 ]
}

@test "restore skips parts that were never backed up" {
  mkdir -p "$BACKUP_REMOTE/data"; echo '{}' > "$BACKUP_REMOTE/data/auth.json"
  run restore.sh
  [ "$status" -eq 0 ]
  [ -f "$D/auth.json" ]
  [ ! -e "$S" ]
}

@test "skills installed in any of the three folders opencode reads are backed up and restored" {
  for d in "$C/skills/a" "$HOME/.claude/skills/b" "$HOME/.agents/skills/c"; do mkdir -p "$d"; echo "skill $(basename "$d")" > "$d/SKILL.md"; done
  run backup.sh
  [ "$status" -eq 0 ]
  [ -f "$BACKUP_REMOTE/config/skills/a/SKILL.md" ]
  [ -f "$BACKUP_REMOTE/claude-skills/b/SKILL.md" ]
  [ -f "$BACKUP_REMOTE/agents-skills/c/SKILL.md" ]
  export HOME="$BATS_TEST_TMPDIR/fresh"; mkdir -p "$HOME"
  run restore.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.config/opencode/skills/a/SKILL.md")" = "skill a" ]
  [ "$(cat "$HOME/.claude/skills/b/SKILL.md")" = "skill b" ]
  [ "$(cat "$HOME/.agents/skills/c/SKILL.md")" = "skill c" ]
}

@test "extra directories round-trip under extra/<name>, with nothing excluded" {
  X="$HOME/tooldata"
  export BACKUP_EXTRA_DIRS="tool=$X"
  run restore.sh --extra
  [ "$status" -eq 0 ]
  mkdir -p "$X/bin" "$X/log" "$X/releases/v1"
  echo b > "$X/bin/app"; echo l > "$X/log/x.log"; echo '{}' > "$X/composer.lock"; echo m > "$X/releases/v1/meta.json"
  run backup.sh
  [ "$status" -eq 0 ]
  [ -f "$BACKUP_REMOTE/extra/tool/bin/app" ]
  [ -f "$BACKUP_REMOTE/extra/tool/log/x.log" ]
  [ -f "$BACKUP_REMOTE/extra/tool/composer.lock" ]
  [ -f "$BACKUP_REMOTE/extra/tool/releases/v1/meta.json" ]

  export HOME="$BATS_TEST_TMPDIR/home2"; mkdir -p "$HOME"
  export BACKUP_EXTRA_DIRS="tool=$HOME/tooldata"
  run restore.sh --extra
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool restored"* ]]
  [ "$(cat "$HOME/tooldata/releases/v1/meta.json")" = "m" ]
  [ -f "$HOME/tooldata/composer.lock" ]
}

@test "an extra directory that was not restored at boot is not backed up" {
  X="$HOME/tooldata"; mkdir -p "$X"; echo partial > "$X/f"
  mkdir -p "$BACKUP_REMOTE/extra/tool"; echo good > "$BACKUP_REMOTE/extra/tool/f"
  export BACKUP_EXTRA_DIRS="tool=$X"
  run backup.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"not restored at boot"* ]]
  [ "$(cat "$BACKUP_REMOTE/extra/tool/f")" = "good" ]
}

@test "the restore of extra directories does not touch opencode's own" {
  mkdir -p "$BACKUP_REMOTE/data" "$BACKUP_REMOTE/extra/tool"
  echo '{"a":1}' > "$BACKUP_REMOTE/data/auth.json"; echo t > "$BACKUP_REMOTE/extra/tool/f"
  export BACKUP_EXTRA_DIRS="tool=$HOME/tooldata"
  run restore.sh --extra
  [ "$status" -eq 0 ]
  [ -f "$HOME/tooldata/f" ]
  [ ! -e "$D/auth.json" ]
  run restore.sh
  [ -f "$D/auth.json" ]
  [ ! -e "$D/extra" ]
}

@test "BACKUP_EXTRA_DIRS entries that are not valid are skipped with a warning" {
  mkdir -p "$HOME/ok"; echo y > "$HOME/ok/f"
  export BACKUP_EXTRA_DIRS="Bad=/x,rel=relative/path noequals ok=$HOME/ok ok=$HOME/other"
  run restore.sh --extra
  [ "$status" -eq 0 ]
  [[ "$output" == *"'Bad=/x' skipped"* ]]
  [[ "$output" == *"'rel=relative/path' skipped"* ]]
  [[ "$output" == *"'noequals' skipped"* ]]
  [[ "$output" == *"'ok=$HOME/other' skipped"* ]]
  run backup.sh
  [ -f "$BACKUP_REMOTE/extra/ok/f" ]
  [ ! -e "$BACKUP_REMOTE/extra/rel" ]
}
