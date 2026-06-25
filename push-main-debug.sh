#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REMOTE="git@github.com:wxyjay/lunch-http-server-releases.git"

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

git status --short
read -r -p "Commit all non-ignored changes and push to origin/${branch}? [y/N] " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
  git add -A
  if git diff --cached --quiet; then
    echo "No staged changes to commit."
  else
    git commit -m "release repo update $(date -u +%Y-%m-%d)"
  fi
  git push -u origin "$branch"
fi
