#!/usr/bin/env bash
set -euo pipefail

APP_NAME="LiveWallpaper"
BUNDLE_ID="com.sakana.livewallpaper"
VERSION="${1:-0.0.1}"
BUILD_NUMBER="${2:-1}"
SPARKLE_APPCAST_URL="${SPARKLE_APPCAST_URL:-https://raw.githubusercontent.com/Narcissus-tazetta/LiveWallpaper/main/docs/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
ARCH_MODE="${ARCH_MODE:-universal}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
ZIP_PATH="$DIST_DIR/${APP_NAME}-macos-v${VERSION}.zip"
ARM_EXEC_PATH="$ROOT_DIR/.build/arm64-apple-macosx/release/${APP_NAME}"
X64_EXEC_PATH="$ROOT_DIR/.build/x86_64-apple-macosx/release/${APP_NAME}"
UNIVERSAL_EXEC_PATH="$DIST_DIR/${APP_NAME}-universal"
EXEC_PATH="$ARM_EXEC_PATH"
ICON_PATH="$ROOT_DIR/Sources/LiveWallpaper/Resources/AppIcon.icns"
SPARKLE_FRAMEWORK_PATH="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
PUBLIC_KEY_FILE="$ROOT_DIR/sparkle-public.pem"

normalize_public_key() {
  local raw="$1"
  if [[ "$raw" == *"BEGIN PUBLIC KEY"* ]]; then
    printf '%s' "$raw" | sed $'s/\\\\n/\\\n/g' | sed '/-----BEGIN PUBLIC KEY-----/d;/-----END PUBLIC KEY-----/d' | tr -d '[:space:]'
  else
    printf '%s' "$raw" | tr -d '[:space:]'
  fi
}

validate_sparkle_public_key() {
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

if len(raw) != 32:
    print(
        f"Sparkle public key must be 32-byte raw Ed25519 key (got {len(raw)} bytes). "
        "Do not use PEM/DER; use Sparkle raw key base64.",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

mkdir -p "$DIST_DIR"

cd "$ROOT_DIR"
echo "[1/5] Building release binary..."
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

validate_sparkle_public_key "$SPARKLE_PUBLIC_ED_KEY"

echo "[2/5] Creating .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp -f "$EXEC_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
cp -f "$ICON_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"
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
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>SUFeedURL</key>
  <string>${SPARKLE_APPCAST_URL}</string>
  <key>SUPublicEDKey</key>
  <string>${SPARKLE_PUBLIC_ED_KEY}</string>
</dict>
</plist>
PLIST

echo "[3/5] Ad-hoc signing app bundle..."
codesign --force --deep --sign - "$APP_DIR"

echo "[4/5] Creating zip..."
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo "[5/5] Done"
echo "App: $APP_DIR"
echo "Zip: $ZIP_PATH"
ls -lh "$ZIP_PATH"

if [[ -f "$UNIVERSAL_EXEC_PATH" ]]; then
  rm -f "$UNIVERSAL_EXEC_PATH"
fi
