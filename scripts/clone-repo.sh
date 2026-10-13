#!/usr/bin/env bash
# Clone a repo into ~/work/<name> so it shows up as a project in opencode (open it from the web UI, or
# `opencode attach` / start opencode in that directory).
#   clone-repo.sh <name> --repo <https github.com or Azure DevOps url> [--branch <branch>]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "clone-repo: $*" >&2; exit "${2:-1}"; }

name="${1:-}"; shift || true
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "invalid name (lowercase letters, digits, '-', max 31 chars)" 2

repo=""; branch=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)   repo="${2:-}"; shift 2 ;;
    --branch) branch="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done
[[ -n "$repo" ]] || die "--repo is required" 2

# https only, known git hosts only, optional bare username (no password), no shell metacharacters.
re='^https://([A-Za-z0-9._-]+@)?(github\.com|dev\.azure\.com|[A-Za-z0-9-]+\.visualstudio\.com)/[A-Za-z0-9._~%/-]+$'
[[ "$repo" =~ $re ]] || die "repo URL must be an https github.com or Azure DevOps URL without credentials" 2
[[ -z "$branch" || "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid branch name" 2
[[ "$branch" != -* ]] || die "invalid branch name" 2

dir="$HOME/work/$name"
[[ ! -e "$dir" ]] || die "directory $dir already exists"
# Credential helper is injected through env, so the token is never written to .git/config.
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0="$here/git-credential-env.sh"
args=(clone)
[[ -n "$branch" ]] && args+=(--branch "$branch")
git "${args[@]}" -- "$repo" "$dir" >&2 || die "git clone failed"
echo "cloned into $dir"
