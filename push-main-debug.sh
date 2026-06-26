#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REMOTE="git@github.com:wxyjay/lunch-http-server-releases.git"

cleanup_tracked_ignored_files() {
  local tracked_ignored=()
  while IFS= read -r path; do
    tracked_ignored+=("$path")
  done < <(git ls-files -ci --exclude-standard)

  if (( ${#tracked_ignored[@]} == 0 )); then
    return
  fi

  echo "Removing tracked ignored files from git index:"
  printf '  %s\n' "${tracked_ignored[@]}"
  git rm -r --cached -- "${tracked_ignored[@]}"
}

assert_no_public_sensitive_paths() {
  local staged_paths
  staged_paths="$(git diff --cached --name-only)"
  if [[ -z "$staged_paths" ]]; then
    return
  fi

  local blocked=()
  while IFS= read -r path; do
    case "$path" in
      agents|agents.*|agents/*|README|README.*|README/*|*.tmp|*.log|*.tar.gz|*.tar.gz.enc|*.sha256|*.p8|*.pem|*.key|AuthKey_*|artifacts/*|downloads/*|.release-password|.release-password.*|.release-cache/*)
        blocked+=("$path")
        ;;
    esac
  done <<< "$staged_paths"

  if (( ${#blocked[@]} > 0 )); then
    echo "Refusing to commit files that must stay local in this public release repo:" >&2
    printf '  %s\n' "${blocked[@]}" >&2
    echo "Check .gitignore or remove them from the git index first." >&2
    exit 1
  fi
}

fetch_remote_branch() {
  if git remote get-url origin >/dev/null 2>&1; then
    git fetch origin "$branch" >/dev/null 2>&1 || true
  fi
}

remote_branch_exists() {
  git show-ref --verify --quiet "refs/remotes/origin/${branch}"
}

resolve_release_manifest_conflicts_by_remote() {
  local conflicted=()
  while IFS= read -r path; do
    conflicted+=("$path")
  done < <(git diff --name-only --diff-filter=U)

  if (( ${#conflicted[@]} == 0 )); then
    return 0
  fi

  for path in "${conflicted[@]}"; do
    case "$path" in
      manifests/http-server/*.json)
        echo "Resolving manifest conflict with remote version: $path"
        git checkout --ours -- "$path"
        perl -0pi -e 's/\n\z//' "$path"
        git add "$path"
        ;;
      *)
        echo "Cannot auto-resolve conflict outside release manifests: $path" >&2
        return 1
        ;;
    esac
  done

  GIT_EDITOR=true git rebase --continue
}

rebase_onto_remote_if_needed() {
  fetch_remote_branch
  if ! remote_branch_exists; then
    return
  fi

  if git merge-base --is-ancestor "origin/${branch}" HEAD; then
    return
  fi

  echo "Remote origin/${branch} is ahead or diverged; rebasing local commits onto remote."
  if git rebase "origin/${branch}"; then
    return
  fi

  if resolve_release_manifest_conflicts_by_remote; then
    return
  fi

  git rebase --abort || true
  echo "Automatic rebase failed. Resolve conflicts manually, then rerun this script." >&2
  exit 1
}

push_with_rebase_retry() {
  if git push -u origin "$branch"; then
    return
  fi

  echo "Initial push failed, trying to fetch/rebase remote changes and push again."
  rebase_onto_remote_if_needed
  git push -u origin "$branch"
}

cd "$ROOT_DIR"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init -b main
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  read -r -p "Set origin to ${DEFAULT_REMOTE}? [Y/n] " set_remote
  if [[ ! "$set_remote" =~ ^[Nn]$ ]]; then
    git remote add origin "$DEFAULT_REMOTE"
  fi
fi

current_branch="$(git branch --show-current 2>/dev/null || echo main)"
read -r -p "Branch [main/debug] (Enter keeps ${current_branch}): " branch
branch="${branch:-$current_branch}"
if [[ "$branch" != "main" && "$branch" != "debug" ]]; then
  echo "Branch must be main or debug." >&2
  exit 1
fi

if git show-ref --verify --quiet "refs/heads/${branch}"; then
  git switch "$branch"
else
  git switch -c "$branch"
fi

rebase_onto_remote_if_needed
cleanup_tracked_ignored_files
git status --short
read -r -p "Commit all non-ignored changes and push to origin/${branch}? [y/N] " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
  git add -A
  cleanup_tracked_ignored_files
  assert_no_public_sensitive_paths
  if git diff --cached --quiet; then
    echo "No staged changes to commit."
  else
    git commit -m "release repo update $(date -u +%Y-%m-%d)"
  fi
  push_with_rebase_retry
fi
