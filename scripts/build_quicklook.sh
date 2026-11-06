#!/bin/bash
# Builds LiveWallpaperQuickLook.appex (universal), the Quick Look thumbnail extension
# that gives .lwpkg files a Finder thumbnail. It ships in the app's Contents/PlugIns.
#
# usage: scripts/build_quicklook.sh <version> [output-dir] [debug|release]
#   output-dir defaults to .build/quicklook
#   CODESIGN_IDENTITY selects the signing identity (default: ad-hoc)
set -euo pipefail

VERSION="${1:?usage: build_quicklook.sh <version> [output-dir] [debug|release]}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${2:-$ROOT_DIR/.build/quicklook}"
CONFIGURATION="${3:-release}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
APP_BUNDLE_ID="com.sakana.livewallpaper"
MODULE_NAME="LiveWallpaperQuickLook"
APPEX="$OUT_DIR/$MODULE_NAME.appex"
ENTITLEMENTS="$ROOT_DIR/QuickLook/QuickLookThumbnail.entitlements"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SOURCES=(
  "$ROOT_DIR/QuickLook/ThumbnailProvider.swift"
  "$ROOT_DIR/QuickLook/PackageThumbnailLocator.swift"
  "$ROOT_DIR/QuickLook/ZipArchiveReader.swift"
)

OPT_FLAGS=(-O)
if [[ "$CONFIGURATION" == "debug" ]]; then
  OPT_FLAGS=(-Onone -g)
fi

# Extensions have no main(); _NSExtensionMain (Foundation) runs the XPC listener and
# instantiates NSExtensionPrincipalClass.
for ARCH in arm64 x86_64; do
  xcrun swiftc "${OPT_FLAGS[@]}" \
    -swift-version 5 \
    -module-name "$MODULE_NAME" \
    -target "$ARCH-apple-macos13.0" \
    -application-extension \
    -parse-as-library \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -framework QuickLookThumbnailing -framework ImageIO -framework CoreGraphics \
    "${SOURCES[@]}" \
    -o "$WORK_DIR/$MODULE_NAME-$ARCH"
done

rm -rf "$APPEX"
mkdir -p "$APPEX/Contents/MacOS"
lipo -create "$WORK_DIR/$MODULE_NAME-arm64" "$WORK_DIR/$MODULE_NAME-x86_64" \
  -output "$APPEX/Contents/MacOS/$MODULE_NAME"

cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>${APP_BUNDLE_ID}.QuickLookThumbnail</string>
  <key>CFBundleName</key>
  <string>${MODULE_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>LiveWallpaper Thumbnail</string>
  <key>CFBundleExecutable</key>
  <string>${MODULE_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>XPC!</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.quicklook.thumbnail</string>
    <key>NSExtensionPrincipalClass</key>
    <string>${MODULE_NAME}.ThumbnailProvider</string>
    <key>NSExtensionAttributes</key>
    <dict>
      <key>QLSupportedContentTypes</key>
      <array>
        <string>${APP_BUNDLE_ID}.package</string>
      </array>
      <key>QLThumbnailMinimumDimension</key>
      <integer>0</integer>
    </dict>
  </dict>
</dict>
</plist>
PLIST

# Quick Look only loads sandboxed extensions. When this appex is embedded, the app must
# be signed without --deep afterwards, or the entitlement is stripped again.
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APPEX" >/dev/null
echo "$APPEX"
