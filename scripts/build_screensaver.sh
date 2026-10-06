#!/bin/bash
# Builds LiveWallpaper.saver (universal) from ScreenSaver/ plus the app sources it
# shares, so trim/loop and fit behave exactly like the desktop wallpaper.
#
# usage: scripts/build_screensaver.sh <version> [output-dir] [debug|release]
#   output-dir defaults to .build/screensaver (where a `swift run` build finds it)
set -euo pipefail

VERSION="${1:?usage: build_screensaver.sh <version> [output-dir] [debug|release]}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${2:-$ROOT_DIR/.build/screensaver}"
CONFIGURATION="${3:-release}"
SAVER="$OUT_DIR/LiveWallpaper.saver"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SOURCES=(
  "$ROOT_DIR/ScreenSaver/LiveWallpaperSaverView.swift"
  "$ROOT_DIR/Sources/LiveWallpaper/Core/Models/ScreenSaverConfig.swift"
  "$ROOT_DIR/Sources/LiveWallpaper/Core/Models/WallpaperTypes.swift"
  "$ROOT_DIR/Sources/LiveWallpaper/Core/Models/WallpaperGeometry.swift"
  "$ROOT_DIR/Sources/LiveWallpaper/Core/Services/WallpaperLoopBuilder.swift"
  "$ROOT_DIR/Sources/LiveWallpaper/App/AppLog.swift"
)

OPT_FLAGS=(-O)
if [[ "$CONFIGURATION" == "debug" ]]; then
  OPT_FLAGS=(-Onone -g)
fi

for ARCH in arm64 x86_64; do
  xcrun swiftc "${OPT_FLAGS[@]}" \
    -swift-version 5 \
    -module-name LiveWallpaperSaver \
    -target "$ARCH-apple-macos13.0" \
    -emit-library -Xlinker -bundle \
    -framework ScreenSaver -framework AVFoundation \
    "${SOURCES[@]}" \
    -o "$WORK_DIR/LiveWallpaperSaver-$ARCH"
done

rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
lipo -create "$WORK_DIR/LiveWallpaperSaver-arm64" "$WORK_DIR/LiveWallpaperSaver-x86_64" \
  -output "$SAVER/Contents/MacOS/LiveWallpaperSaver"

# Thumbnails shown in System Settings' screen saver list.
ICON="$ROOT_DIR/Sources/LiveWallpaper/Resources/AppIcon.icns"
sips -s format png -z 58 58 "$ICON" --out "$SAVER/Contents/Resources/thumbnail.png" >/dev/null
sips -s format png -z 116 116 "$ICON" --out "$SAVER/Contents/Resources/thumbnail@2x.png" >/dev/null

# LWBuildID changes on every build so the app can tell an outdated install apart
# even when the version string is unchanged (development builds).
cat > "$SAVER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.sakana.livewallpaper.screensaver</string>
  <key>CFBundleName</key>
  <string>LiveWallpaper</string>
  <key>CFBundleDisplayName</key>
  <string>LiveWallpaper</string>
  <key>CFBundleExecutable</key>
  <string>LiveWallpaperSaver</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LWBuildID</key>
  <string>$(uuidgen)</string>
  <key>NSPrincipalClass</key>
  <string>LiveWallpaperSaverView</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$SAVER" >/dev/null
echo "$SAVER"
