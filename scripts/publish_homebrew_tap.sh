#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TAP_SOURCE_DIR="$ROOT_DIR/homebrew-tap"
TAP_REPO="Narcissus-tazetta/homebrew-tap"
TAP_BRANCH="${HOMEBREW_TAP_BRANCH:-main}"
WORK_DIR="${RUNNER_TEMP:-/tmp}/homebrew-tap-publish"

if [[ ! -f "$TAP_SOURCE_DIR/Casks/livewallpaper.rb" ]]; then
  echo "Missing cask: $TAP_SOURCE_DIR/Casks/livewallpaper.rb" >&2
  exit 1
fi

TOKEN="${HOMEBREW_TAP_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "$TOKEN" ]]; then
  echo "HOMEBREW_TAP_TOKEN or GITHUB_TOKEN is required to publish the tap" >&2
  exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

if gh repo view "$TAP_REPO" >/dev/null 2>&1; then
  git clone --depth 1 --branch "$TAP_BRANCH" \
    "https://x-access-token:${TOKEN}@github.com/${TAP_REPO}.git" "$WORK_DIR/repo" 2>/dev/null \
    || git clone --depth 1 \
      "https://x-access-token:${TOKEN}@github.com/${TAP_REPO}.git" "$WORK_DIR/repo"
else
  gh repo create "$TAP_REPO" --public --description "Homebrew tap for LiveWallpaper"
  git clone --depth 1 \
    "https://x-access-token:${TOKEN}@github.com/${TAP_REPO}.git" "$WORK_DIR/repo"
fi

cd "$WORK_DIR/repo"
git config user.name "${GIT_AUTHOR_NAME:-github-actions}"
git config user.email "${GIT_AUTHOR_EMAIL:-github-actions@github.com}"

mkdir -p Casks
cp "$TAP_SOURCE_DIR/Casks/livewallpaper.rb" Casks/livewallpaper.rb
if [[ -f "$TAP_SOURCE_DIR/README.md" ]]; then
  cp "$TAP_SOURCE_DIR/README.md" README.md
fi

if [[ -n "$(git status --porcelain)" ]]; then
  git add Casks/livewallpaper.rb README.md
  git commit -m "chore(cask): livewallpaper $(ruby -e 'print File.read("Casks/livewallpaper.rb")[/version "([^"]+)"/, 1]')"
  git push -u origin "HEAD:${TAP_BRANCH}"
  echo "Published ${TAP_REPO}@${TAP_BRANCH}"
else
  echo "Homebrew tap is already up to date"
fi
