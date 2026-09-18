#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/launcher"
DYLIB_DIR="$ROOT_DIR/AntigravityTun"
PROXY_DIR="$ROOT_DIR/tools/mitm_proxy"
OUTPUT_DIR="$ROOT_DIR/build_output"
APP_NAME="AntigravityProxyLauncher"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/Resources/version.txt")"
ARCH="${1:-}"

case "$ARCH" in
  x86_64)
    GOARCH="amd64"
    ;;
  arm64)
    GOARCH="arm64"
    ;;
  *)
    echo "usage: $0 <x86_64|arm64>" >&2
    exit 2
    ;;
esac

command -v xcodegen >/dev/null 2>&1 || {
  echo "error: xcodegen is required (brew install xcodegen)" >&2
  exit 1
}

APP_BUILD_DIR="$OUTPUT_DIR/$ARCH"
APP_BUNDLE="$APP_BUILD_DIR/${APP_NAME}.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INTERMEDIATE_DIR="$OUTPUT_DIR/intermediates/$ARCH"
DYLIB_BUILD_DIR="$INTERMEDIATE_DIR/dylib"
DYLIB_BIN="$DYLIB_BUILD_DIR/Release/libAntigravityTun.dylib"
PROXY_BIN="$INTERMEDIATE_DIR/mitm_proxy"

DMG_NAME="${APP_NAME}_${VERSION}-macos_${ARCH}.dmg"
ZIP_NAME="${APP_NAME}_${VERSION}-macos_${ARCH}.zip"
SUMS_NAME="SHA256SUMS-${ARCH}.txt"

echo "=== Building ${APP_NAME} v${VERSION} for macOS ${ARCH} ==="
echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
echo "Host: $(uname -m)"

rm -rf "$APP_BUILD_DIR" "$INTERMEDIATE_DIR"
rm -f "$OUTPUT_DIR/$DMG_NAME" "$OUTPUT_DIR/$ZIP_NAME" "$OUTPUT_DIR/$SUMS_NAME"
mkdir -p "$OUTPUT_DIR" "$INTERMEDIATE_DIR"

echo "[1/6] Building libAntigravityTun.dylib (${ARCH})..."
xcodebuild \
  -project "$DYLIB_DIR/AntigravityTun.xcodeproj" \
  -scheme AntigravityTun \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  ARCHS="$ARCH" \
  ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=13.0 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  SYMROOT="$DYLIB_BUILD_DIR" \
  build

test -f "$DYLIB_BIN"

echo "[2/6] Building Go MITM proxy (${GOARCH})..."
(
  cd "$PROXY_DIR"
  GOOS=darwin GOARCH="$GOARCH" go build -trimpath -o "$PROXY_BIN" .
)
test -f "$PROXY_BIN"

echo "[3/6] Generating launcher Xcode project..."
(
  cd "$PROJECT_DIR"
  xcodegen generate
)
test -d "$PROJECT_DIR/AntigravityProxyLauncher.xcodeproj"

echo "[4/6] Building launcher (${ARCH})..."
xcodebuild \
  -project "$PROJECT_DIR/AntigravityProxyLauncher.xcodeproj" \
  -scheme AntigravityProxyLauncher \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  ARCHS="$ARCH" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CONFIGURATION_BUILD_DIR="$APP_BUILD_DIR" \
  build

test -d "$APP_BUNDLE"
test -f "$APP_BIN"

echo "[5/6] Bundling and verifying ${ARCH} components..."
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$DYLIB_BIN" "$APP_BUNDLE/Contents/Resources/libAntigravityTun.dylib"
cp "$PROXY_BIN" "$APP_BUNDLE/Contents/Resources/mitm_proxy"
if [ -f "$PROXY_DIR/.env" ]; then
  cp "$PROXY_DIR/.env" "$APP_BUNDLE/Contents/Resources/.env"
fi

verify_arch() {
  local file="$1"
  local arches
  arches="$(lipo -archs "$file")"
  if [ "$arches" != "$ARCH" ]; then
    echo "error: expected ${ARCH}, got '${arches}': ${file}" >&2
    exit 1
  fi
  echo "  OK: ${file} -> ${arches}"
}

verify_arch "$APP_BIN"
verify_arch "$APP_BUNDLE/Contents/Resources/libAntigravityTun.dylib"
verify_arch "$APP_BUNDLE/Contents/Resources/mitm_proxy"

for dylib in "$APP_BUNDLE/Contents/MacOS/"*.dylib; do
  [ -e "$dylib" ] || continue
  verify_arch "$dylib"
done

echo "[6/6] Creating DMG and ZIP..."
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$APP_BUNDLE" \
  -ov \
  -format UDZO \
  "$OUTPUT_DIR/$DMG_NAME"

ditto -c -k --keepParent "$APP_BUNDLE" "$OUTPUT_DIR/$ZIP_NAME"

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > "$SUMS_NAME"
)

echo ""
echo "=== Done ==="
echo "  Architecture: $ARCH"
echo "  DMG: $OUTPUT_DIR/$DMG_NAME"
echo "  ZIP: $OUTPUT_DIR/$ZIP_NAME"
echo "  Checksums: $OUTPUT_DIR/$SUMS_NAME"
