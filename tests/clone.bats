#!/usr/bin/env bats
# clone-repo.sh: URL validation and credential handling (git is stubbed).

setup() {
  unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/work" "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$GIT_LOG"
env | grep -E '^(GIT_CONFIG|GIT_TERMINAL)' >> "$GIT_LOG"
if [[ "$1" == clone ]]; then mkdir -p "${@: -1}/.git"; fi
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  export GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  export PATH="$BATS_TEST_TMPDIR/bin:$BATS_TEST_DIRNAME/../scripts:$PATH"
  unset AZDO_PAT GITHUB_TOKEN
}

GH="https://github.com/acme/repo"
AZ="https://dev.azure.com/acme/proj/_git/repo"

@test "invalid names are refused" {
  for n in "" "Up" "../x" "-x" "a b" "a;b" "$(printf 'a%.0s' {1..40})"; do
    run clone-repo.sh "$n" --repo "$GH"
    [ "$status" -ne 0 ]
  done
}

@test "--repo is required" {
  run clone-repo.sh foo
  [ "$status" -eq 2 ]
}

@test "unknown hosts, plain http, ssh or credential-bearing URLs are refused" {
  for u in "https://gitlab.com/a/b" "http://github.com/a/b" "git@github.com:a/b.git" "https://u:pw@github.com/a/b" \
           "http://dev.azure.com/o/p/_git/r" "file:///etc" "https://dev.azure.com/o/p/_git/r;rm" "--upload-pack=x"; do
    run clone-repo.sh foo --repo "$u"
    [ "$status" -ne 0 ]
    [[ "$output" == *"repo URL"* ]]
  done
  [ ! -e "$GIT_LOG" ]
}

@test "github and Azure DevOps repos are cloned into ~/work/<name>" {
  run clone-repo.sh foo --repo "$GH"
  [ "$status" -eq 0 ]
  [ -d "$HOME/work/foo/.git" ]
  run clone-repo.sh bar --repo "$AZ" --branch release/1.0
  [ "$status" -eq 0 ]
  grep -q -- "--branch release/1.0" "$GIT_LOG"
}

@test "bad branch names and an existing directory are refused" {
  for b in "-x" "a;b" 'a b'; do
    run clone-repo.sh foo --repo "$GH" --branch "$b"
    [ "$status" -ne 0 ]
  done
  mkdir "$HOME/work/taken"
  run clone-repo.sh taken --repo "$GH"
  [ "$status" -ne 0 ]
}

@test "the token never reaches the command line or .git/config: only a credential helper is injected" {
  export GITHUB_TOKEN=ghp_SECRETVALUE
  run clone-repo.sh foo --repo "$GH"
  [ "$status" -eq 0 ]
  run grep -c ghp_SECRETVALUE "$GIT_LOG"
  [ "$output" = 0 ]
  grep -q "GIT_CONFIG_KEY_0=credential.helper" "$GIT_LOG"
}

@test "git-credential-env serves the right token per host and nothing for others" {
  export GITHUB_TOKEN=gh-tok AZDO_PAT=az-tok
  run bash -c 'printf "host=github.com\n\n" | git-credential-env.sh get'
  [[ "$output" == *"password=gh-tok"* ]]
  run bash -c 'printf "host=dev.azure.com\n\n" | git-credential-env.sh get'
  [[ "$output" == *"password=az-tok"* ]]
  run bash -c 'printf "host=evil.example\n\n" | git-credential-env.sh get'
  [ -z "$output" ]
}
