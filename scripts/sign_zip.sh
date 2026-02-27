#!/usr/bin/env bash
set -euo pipefail

PRIVATE_KEY_PATH="${1:?private key path required}"
ZIP_PATH="${2:?zip path required}"

if [[ ! -f "$PRIVATE_KEY_PATH" ]]; then
  echo "private key not found: $PRIVATE_KEY_PATH" >&2
  exit 1
fi

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "zip not found: $ZIP_PATH" >&2
  exit 1
fi

openssl pkeyutl -sign -inkey "$PRIVATE_KEY_PATH" -rawin -in "$ZIP_PATH" | openssl base64 -A
