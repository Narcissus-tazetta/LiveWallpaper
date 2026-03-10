#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?version required}"
OUTPUT_PATH="${2:-dist/release-notes.md}"
CURRENT_TAG="v${VERSION}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p "$(dirname "$OUTPUT_PATH")"

REMOTE_URL="$(git config --get remote.origin.url || true)"
if [[ -z "$REMOTE_URL" ]]; then
  REMOTE_URL="https://github.com/Narcissus-tazetta/LiveWallpaper"
fi

if [[ "$REMOTE_URL" =~ ^git@github.com:(.+)\.git$ ]]; then
  REPO_SLUG="${BASH_REMATCH[1]}"
  REPO_URL="https://github.com/${REPO_SLUG}"
elif [[ "$REMOTE_URL" =~ ^https://github.com/(.+)\.git$ ]]; then
  REPO_SLUG="${BASH_REMATCH[1]}"
  REPO_URL="https://github.com/${REPO_SLUG}"
elif [[ "$REMOTE_URL" =~ ^https://github.com/(.+)$ ]]; then
  REPO_SLUG="${BASH_REMATCH[1]}"
  REPO_URL="https://github.com/${REPO_SLUG}"
else
  REPO_URL="https://github.com/Narcissus-tazetta/LiveWallpaper"
fi

PREV_TAG="$(git tag --list 'v*' --sort=-v:refname | grep -vx "$CURRENT_TAG" | head -n 1 || true)"

if [[ -n "$PREV_TAG" ]]; then
  RANGE="${PREV_TAG}..HEAD"
  COMPARE_URL="${REPO_URL}/compare/${PREV_TAG}...${CURRENT_TAG}"
else
  RANGE="HEAD"
  COMPARE_URL=""
fi

{
  echo "## LiveWallpaper ${CURRENT_TAG}"
  echo
  if [[ -n "$PREV_TAG" ]]; then
    echo "Changes since ${PREV_TAG}."
    echo
    echo "Compare: ${COMPARE_URL}"
    echo
  else
    echo "Initial release notes based on current commits."
    echo
  fi
  echo "### Commits"

  COMMIT_LINES="$(git log --no-merges --pretty=format:'%h%x09%s' ${RANGE} || true)"
  if [[ -z "$COMMIT_LINES" ]]; then
    echo "- No code changes detected in this range."
  else
    emitted=0
    while IFS=$'\t' read -r short_hash subject; do
      [[ -z "$short_hash" ]] && continue
      if [[ "$subject" =~ ^chore:\ update\ appcast\  ]]; then
        continue
      fi
      echo "- ${subject} ([${short_hash}](${REPO_URL}/commit/${short_hash}))"
      emitted=1
    done <<< "$COMMIT_LINES"
    if [[ $emitted -eq 0 ]]; then
      echo "- No user-facing code changes detected in this range."
    fi
  fi
} > "$OUTPUT_PATH"

echo "Generated: $OUTPUT_PATH"
