#!/usr/bin/env bats
# seed-config.sh: AGENTS.md and opencode.json.

setup() {
  unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export CONFIG_DIR="$BATS_TEST_DIRNAME/../config"
  export PATH="$BATS_TEST_DIRNAME/../scripts:$PATH"
  OJ="$HOME/.config/opencode/opencode.json"
}

@test "installs AGENTS.md into ~/work and the base opencode.json" {
  run seed-config.sh
  [ "$status" -eq 0 ]
  grep -q "clone-repo.sh" "$HOME/.config/opencode/AGENTS.md"
  [ "$(jq -r '."$schema"' "$OJ")" = "https://opencode.ai/config.json" ]
}

@test "AGENTS.md is always refreshed from the image" {
  mkdir -p "$HOME/.config/opencode"; echo stale > "$HOME/.config/opencode/AGENTS.md"
  seed-config.sh
  [[ "$(cat "$HOME/.config/opencode/AGENTS.md")" != stale ]]
}

@test "an existing opencode.json keeps its keys" {
  mkdir -p "$(dirname "$OJ")"; echo '{"theme":"dark","model":"a/b"}' > "$OJ"
  seed-config.sh
  [ "$(jq -r .theme "$OJ")" = dark ]
  [ "$(jq -r .model "$OJ")" = a/b ]
}

@test "invalid opencode.json is left untouched and reported" {
  mkdir -p "$(dirname "$OJ")"; echo 'not json {' > "$OJ"
  run seed-config.sh
  [ "$status" -ne 0 ]
  [ "$(cat "$OJ")" = "not json {" ]
}

@test "fragments extend AGENTS.md and opencode.json in name order" {
  cfg="$BATS_TEST_TMPDIR/cfg"; cp -r "$CONFIG_DIR" "$cfg"; export CONFIG_DIR="$cfg"
  mkdir -p "$cfg/AGENTS.d" "$cfg/settings.d"
  echo "## Tool B" > "$cfg/AGENTS.d/20-b.md"; echo "## Tool A" > "$cfg/AGENTS.d/10-a.md"
  echo '{"share":"disabled"}' > "$cfg/settings.d/10.json"
  seed-config.sh
  [ "$(grep -n 'Tool A' "$HOME/.config/opencode/AGENTS.md" | cut -d: -f1)" -lt "$(grep -n 'Tool B' "$HOME/.config/opencode/AGENTS.md" | cut -d: -f1)" ]
  [ "$(jq -r .share "$OJ")" = disabled ]
}

@test "AUTO_APPROVE=1 sets the permissions to allow, otherwise none are set" {
  seed-config.sh
  [ "$(jq -r '.permission // "none"' "$OJ")" = none ]
  AUTO_APPROVE=1 seed-config.sh
  [ "$(jq -r .permission.bash "$OJ")" = allow ]
  [ "$(jq -r .permission.external_directory "$OJ")" = allow ]
}

@test "AGENTS.md has no secret-looking value and names the helper" {
  run grep -E "hf_[A-Za-z0-9]{10,}|AKIA|password=" "$CONFIG_DIR/AGENTS.md"
  [ "$status" -ne 0 ]
  grep -q "clone-repo.sh" "$CONFIG_DIR/AGENTS.md"
}

@test "a legacy ~/work/AGENTS.md written by the image is removed, a user's own is kept" {
  mkdir -p "$HOME/work"
  head -1 "$CONFIG_DIR/AGENTS.md" > "$HOME/work/AGENTS.md"
  seed-config.sh
  [ ! -e "$HOME/work/AGENTS.md" ]
  echo "# my own rules" > "$HOME/work/AGENTS.md"
  seed-config.sh
  [ "$(cat "$HOME/work/AGENTS.md")" = "# my own rules" ]
}

@test "AGENTS.md tells the agent to install skills where they are backed up" {
  grep -q '~/.config/opencode/skills/<name>/SKILL.md' "$CONFIG_DIR/AGENTS.md"
}
