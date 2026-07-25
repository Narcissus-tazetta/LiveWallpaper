#!/usr/bin/env bash
# X.Y.Z から CFBundleVersion / sparkle:version を機械的に導出する。
#
# Sparkleが「更新があるか」を判定するのはこのビルド番号だけで、
# 1.2.6 のような表示用文字列は見ていない。手入力だとローカルビルドが
# リリース列を追い越して「最新版です(でも1.2.6があります)」という
# 矛盾したダイアログになるため、必ずバージョンから導出する。
#
# 方式: major*10000 + minor*100 + patch (例: 1.2.6 -> 10206)
# ドット除去(1.2.6 -> 126)は 1.2.10 -> 1210 > 1.3.0 -> 130 と逆転するため使わない。
set -euo pipefail

VERSION="${1:?version required (X.Y.Z)}"

if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "version must be X.Y.Z with numeric components: $VERSION" >&2
  exit 1
fi

MAJOR=$((10#${BASH_REMATCH[1]}))
MINOR=$((10#${BASH_REMATCH[2]}))
PATCH=$((10#${BASH_REMATCH[3]}))

if ((MINOR > 99 || PATCH > 99)); then
  echo "minor/patch must be <= 99 to keep build numbers ordered: $VERSION" >&2
  exit 1
fi

echo $((MAJOR * 10000 + MINOR * 100 + PATCH))
