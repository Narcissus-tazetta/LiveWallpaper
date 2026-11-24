#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?version required}"
APPCAST="${2:?path to generated appcast required}"
BUILD_NUMBER="$(bash "$(dirname "$0")/derive_build_number.sh" "$VERSION")"
TARGET=docs/appcast.xml

for attempt in 1 2 3; do
  git fetch --no-tags origin refs/heads/main
  git switch --detach FETCH_HEAD
  current=$(sed -n 's/.*<sparkle:version>\([0-9][0-9]*\)<\/sparkle:version>.*/\1/p' "$TARGET" | sed -n '1p')
  if [[ -z "$current" ]]; then
    echo "No build number in $TARGET on main" >&2
    exit 1
  fi
  if ((10#$current >= BUILD_NUMBER)); then
    echo "main already serves build $current"
    exit 0
  fi
  cp "$APPCAST" "$TARGET"
  git add "$TARGET"
  git commit -m "chore: update appcast v$VERSION"
  if git push origin HEAD:refs/heads/main; then
    exit 0
  fi
  echo "Appcast push failed on attempt $attempt" >&2
done
exit 1
