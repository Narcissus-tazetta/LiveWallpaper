#!/usr/bin/env bash
set -euo pipefail

APP_NAME="LiveWallpaper"
BUNDLE_ID="com.sakana.livewallpaper"
VERSION="${1:-0.0.1}"
BUILD_NUMBER="${2:-}"
SPARKLE_APPCAST_URL="${SPARKLE_APPCAST_URL:-https://raw.githubusercontent.com/Narcissus-tazetta/LiveWallpaper/main/docs/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
ARCH_MODE="${ARCH_MODE:-universal}"
# 既定はad-hoc署名。手元の証明書で署名したい場合は
# CODESIGN_IDENTITY="Apple Development: ..." のように上書きする。
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
CREATE_DMG="${CREATE_DMG:-true}"
CREATE_DMG_COMMAND="${CREATE_DMG_COMMAND:-create-dmg}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
ZIP_PATH="$DIST_DIR/${APP_NAME}-macos-v${VERSION}.zip"
DMG_PATH="$DIST_DIR/${APP_NAME}-macos-v${VERSION}.dmg"
ARM_EXEC_PATH="$ROOT_DIR/.build/arm64-apple-macosx/release/${APP_NAME}"
X64_EXEC_PATH="$ROOT_DIR/.build/x86_64-apple-macosx/release/${APP_NAME}"
UNIVERSAL_EXEC_PATH="$DIST_DIR/${APP_NAME}-universal"
EXEC_PATH="$ARM_EXEC_PATH"
ICON_PATH="$ROOT_DIR/Sources/LiveWallpaper/Resources/AppIcon.icns"
SPARKLE_FRAMEWORK_PATH="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
PUBLIC_KEY_FILE="$ROOT_DIR/sparkle-public.pem"
DMG_BACKGROUND_SOURCE="$ROOT_DIR/docs/background.tiff"

# ビルド番号は必ずバージョンから導出する。手入力を許すと、ローカルビルドが
# リリース済みのビルド番号を追い越し、Sparkleが「最新版です(でも新しい版が
# あります)」という矛盾したダイアログを出す状態に陥る。
DERIVED_BUILD_NUMBER="$(bash "$ROOT_DIR/scripts/derive_build_number.sh" "$VERSION")"
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$DERIVED_BUILD_NUMBER"
elif [[ "$BUILD_NUMBER" != "$DERIVED_BUILD_NUMBER" ]]; then
  echo "build number ${BUILD_NUMBER} does not match version ${VERSION}." >&2
  echo "expected ${DERIVED_BUILD_NUMBER}. Omit arg2 to derive it automatically." >&2
  exit 1
fi

normalize_public_key() {
  local raw="$1"
  if [[ "$raw" == *"BEGIN PUBLIC KEY"* ]]; then
    printf '%s' "$raw" | sed $'s/\\\\n/\\\n/g' | sed '/-----BEGIN PUBLIC KEY-----/d;/-----END PUBLIC KEY-----/d' | tr -d '[:space:]'
  else
    printf '%s' "$raw" | tr -d '[:space:]'
  fi
}

normalize_and_validate_sparkle_public_key() {
  local key="$1"
  python3 - "$key" <<'PY'
import base64
import sys

key = sys.argv[1].strip()
try:
    raw = base64.b64decode(key, validate=True)
except Exception:
    print("Sparkle public key must be base64", file=sys.stderr)
    raise SystemExit(1)

if len(raw) == 32:
  print(base64.b64encode(raw).decode("ascii"), end="")
  raise SystemExit(0)

der_prefix = bytes.fromhex("302a300506032b6570032100")
if len(raw) == 44 and raw.startswith(der_prefix):
  normalized = raw[len(der_prefix):]
  print(base64.b64encode(normalized).decode("ascii"), end="")
  raise SystemExit(0)

print(
  f"Sparkle public key must be raw Ed25519 base64 (32 bytes) or compatible DER/SPKI key (got {len(raw)} bytes).",
  file=sys.stderr,
)
raise SystemExit(1)
PY
}

sign_app_bundle() {
  codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR"
  codesign --verify --deep --verbose=2 "$APP_DIR"
}

create_polished_dmg() {
  local stage_dir="$1"
  local background_png="$2"

  "$CREATE_DMG_COMMAND" \
    --volname "$APP_NAME" \
    --window-size 600 400 \
    --background "$background_png" \
    --icon-size 100 \
    --icon "$APP_NAME.app" 150 200 \
    --app-drop-link 450 200 \
    --volicon "$ICON_PATH" \
    --format UDZO \
    "$DMG_PATH" \
    "$stage_dir"
}

mkdir -p "$DIST_DIR"

cd "$ROOT_DIR"
echo "[1/6] Building release binary..."
if [[ "$ARCH_MODE" == "universal" ]]; then
  swift build -c release --arch arm64
  swift build -c release --arch x86_64

  if [[ ! -f "$ARM_EXEC_PATH" ]]; then
    echo "arm64 release binary not found: $ARM_EXEC_PATH" >&2
    exit 1
  fi

  if [[ ! -f "$X64_EXEC_PATH" ]]; then
    echo "x86_64 release binary not found: $X64_EXEC_PATH" >&2
    exit 1
  fi

  lipo -create "$ARM_EXEC_PATH" "$X64_EXEC_PATH" -output "$UNIVERSAL_EXEC_PATH"
  EXEC_PATH="$UNIVERSAL_EXEC_PATH"
else
  swift build -c release --arch arm64
  EXEC_PATH="$ARM_EXEC_PATH"
fi

if [[ ! -f "$EXEC_PATH" ]]; then
  echo "Release binary not found: $EXEC_PATH" >&2
  exit 1
fi

if [[ ! -f "$ICON_PATH" ]]; then
  echo "Icon file not found: $ICON_PATH" >&2
  exit 1
fi

if [[ ! -d "$SPARKLE_FRAMEWORK_PATH" ]]; then
  echo "Sparkle framework not found: $SPARKLE_FRAMEWORK_PATH" >&2
  exit 1
fi

if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]] && [[ -f "$PUBLIC_KEY_FILE" ]]; then
  SPARKLE_PUBLIC_ED_KEY="$(cat "$PUBLIC_KEY_FILE")"
fi

SPARKLE_PUBLIC_ED_KEY="$(normalize_public_key "$SPARKLE_PUBLIC_ED_KEY")"

if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "Sparkle public key is empty. Set SPARKLE_PUBLIC_ED_KEY or provide sparkle-public.pem" >&2
  exit 1
fi

SPARKLE_PUBLIC_ED_KEY="$(normalize_and_validate_sparkle_public_key "$SPARKLE_PUBLIC_ED_KEY")"

echo "[2/6] Creating .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp -f "$EXEC_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
cp -f "$ICON_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"
if [[ -d "$ROOT_DIR/Sources/LiveWallpaper/Resources" ]]; then
  for lproj in "$ROOT_DIR"/Sources/LiveWallpaper/Resources/*.lproj; do
    if [[ -d "$lproj" ]]; then
      cp -R "$lproj" "$APP_DIR/Contents/Resources/"
    fi
  done
fi
cp -R "$SPARKLE_FRAMEWORK_PATH" "$APP_DIR/Contents/MacOS/Sparkle.framework"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>ja</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>ja</string>
    <string>en</string>
    <string>zh-Hant</string>
    <string>vi</string>
    <string>tr</string>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>${BUNDLE_ID}.url</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>livewallpaper</string>
      </array>
    </dict>
  </array>
  <key>SUFeedURL</key>
  <string>${SPARKLE_APPCAST_URL}</string>
  <key>SUPublicEDKey</key>
  <string>${SPARKLE_PUBLIC_ED_KEY}</string>
</dict>
</plist>
PLIST

echo "[3/6] Ad-hoc signing app bundle..."
sign_app_bundle

echo "[4/6] Creating zip..."
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

if [[ "$CREATE_DMG" == "true" ]]; then
  echo "[5/6] Creating dmg..."
  rm -f "$DMG_PATH"

  STAGE_DIR="$DIST_DIR/dmg-stage"
  rm -rf "$STAGE_DIR"
  mkdir -p "$STAGE_DIR"

  # Copy app and create Applications link
  cp -R "$APP_DIR" "$STAGE_DIR/"

  # Use the provided DMG background artwork when available.
  if [[ -f "$DMG_BACKGROUND_SOURCE" ]]; then
    mkdir -p "$STAGE_DIR/.background"
    sips -s format png "$DMG_BACKGROUND_SOURCE" --out "$STAGE_DIR/.background/background.png" >/dev/null
  fi

  if command -v "$CREATE_DMG_COMMAND" >/dev/null 2>&1; then
    create_polished_dmg "$STAGE_DIR" "$STAGE_DIR/.background/background.png"
  else
    echo "create-dmg not found; falling back to hdiutil packaging" >&2
    ln -s /Applications "$STAGE_DIR/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"
  fi

  # Clean up staging
  rm -rf "$STAGE_DIR"
else
  echo "[5/6] Skipping dmg creation"
fi

echo "[6/6] Done"
echo "App: $APP_DIR"
echo "Zip: $ZIP_PATH"
ls -lh "$ZIP_PATH"
if [[ -f "$DMG_PATH" ]]; then
  echo "DMG: $DMG_PATH"
  ls -lh "$DMG_PATH"
fi

if [[ -f "$UNIVERSAL_EXEC_PATH" ]]; then
  rm -f "$UNIVERSAL_EXEC_PATH"
fi

 open dist/LiveWallpaper.app
