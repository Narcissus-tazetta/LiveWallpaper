#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?version required}"
ZIP_PATH="${2:?zip path required}"

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Zip not found: $ZIP_PATH" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CASK_DIR="$ROOT_DIR/homebrew-tap/Casks"
CASK_PATH="$CASK_DIR/livewallpaper.rb"
GITHUB_USER="Narcissus-tazetta"
REPO="LiveWallpaper"
SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

mkdir -p "$CASK_DIR"

RUBY_VERSION_INTERP='#{version}'

cat > "$CASK_PATH" <<RUBY
cask "livewallpaper" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/${GITHUB_USER}/${REPO}/releases/download/v${RUBY_VERSION_INTERP}/LiveWallpaper-macos-v${RUBY_VERSION_INTERP}.zip"
  name "LiveWallpaper"
  desc "Set your favorite videos as Mac desktop wallpaper"
  homepage "https://github.com/${GITHUB_USER}/${REPO}"

  depends_on macos: :ventura

  app "LiveWallpaper.app"

  zap trash: [
    "~/Library/Application Support/LiveWallpaper",
    "~/Library/Preferences/com.sakana.livewallpaper.plist",
    "~/Library/Saved Application State/com.sakana.livewallpaper.savedState",
  ]
end
RUBY

echo "Wrote $CASK_PATH"
echo "version=${VERSION}"
echo "sha256=${SHA256}"
