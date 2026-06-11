#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../launcher" && pwd)"
DYLIB_DIR="$(cd "$(dirname "$0")/../AntigravityTun" && pwd)"
OUTPUT_DIR="$(cd "$(dirname "$0")/../build_output" && pwd)"
APP_NAME="AntigravityProxyLauncher"
VERSION=$(cat "$(dirname "$0")/../launcher/Resources/version.txt" | tr -d '[:space:]')
DERIVED_BASE="$HOME/Library/Developer/Xcode/DerivedData"

echo "=== Building AntigravityProxyLauncher v${VERSION} ==="

# --- Step 1: Build dylib (universal) ---
echo "[1/5] Building libAntigravityTun.dylib (universal)..."
cd "$DYLIB_DIR"

# Build for arm64
xcodebuild -project AntigravityTun.xcodeproj -scheme AntigravityTun -configuration Release \
  -arch arm64 \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  SYMROOT="$DYLIB_DIR/build_arm64" \
  build 2>&1 | grep -E "BUILD|error" || true

# Build for x86_64
xcodebuild -project AntigravityTun.xcodeproj -scheme AntigravityTun -configuration Release \
  -arch x86_64 \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  SYMROOT="$DYLIB_DIR/build_x86" \
  build 2>&1 | grep -E "BUILD|error" || true

# Lipo into universal
mkdir -p "$DYLIB_DIR/build/Release"
ARM64_DYLIB="$DYLIB_DIR/build_arm64/Release/libAntigravityTun.dylib"
X86_DYLIB="$DYLIB_DIR/build_x86/Release/libAntigravityTun.dylib"
DYLIB_SRC="$DYLIB_DIR/build/Release/libAntigravityTun.dylib"
lipo -create "$ARM64_DYLIB" "$X86_DYLIB" -output "$DYLIB_SRC"
rm -rf "$DYLIB_DIR/build_arm64" "$DYLIB_DIR/build_x86"
echo "  Dylib: $(lipo -info "$DYLIB_SRC" | head -1)"

# --- Step 1.5: Build Go Proxy ---
echo "[1.5/5] Building Go MITM Proxy (universal)..."
PROXY_DIR="$PROJECT_DIR/../tools/mitm_proxy"
cd "$PROXY_DIR"
GOOS=darwin GOARCH=arm64 go build -o mitm_proxy_arm64 .
GOOS=darwin GOARCH=amd64 go build -o mitm_proxy_x86_64 .
lipo -create mitm_proxy_arm64 mitm_proxy_x86_64 -output mitm_proxy
rm mitm_proxy_arm64 mitm_proxy_x86_64
echo "  Proxy: $(lipo -info "mitm_proxy" | head -1)"

# --- Step 2: Build app for arm64 ---
echo "[2/5] Building app for arm64..."
cd "$PROJECT_DIR"
xcodebuild -project AntigravityProxyLauncher.xcodeproj -scheme AntigravityProxyLauncher \
  -configuration Release -arch arm64 \
  CONFIGURATION_BUILD_DIR="$OUTPUT_DIR/arm64" \
  build 2>&1 | grep -E "BUILD|error" || true

# --- Step 3: Build app for x86_64 ---
echo "[3/5] Building app for x86_64..."
xcodebuild -project AntigravityProxyLauncher.xcodeproj -scheme AntigravityProxyLauncher \
  -configuration Release -arch x86_64 \
  CONFIGURATION_BUILD_DIR="$OUTPUT_DIR/x86_64" \
  build 2>&1 | grep -E "BUILD|error" || true

# --- Step 4: Create universal binary ---
echo "[4/5] Creating universal binary..."
UNIVERSAL_APP="$OUTPUT_DIR/${APP_NAME}.app"
rm -rf "$UNIVERSAL_APP"

# Copy arm64 app as base
cp -R "$OUTPUT_DIR/arm64/${APP_NAME}.app" "$UNIVERSAL_APP"

# Merge main executable
ARM64_BIN="$OUTPUT_DIR/arm64/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
X86_BIN="$OUTPUT_DIR/x86_64/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
UNIVERSAL_BIN="$UNIVERSAL_APP/Contents/MacOS/${APP_NAME}"

lipo -create "$ARM64_BIN" "$X86_BIN" -output "$UNIVERSAL_BIN"
echo "  App binary: $(lipo -info "$UNIVERSAL_BIN")"

# Merge all nested dylibs (debug.dylib, preview.dylib, etc.)
for dylib in "$UNIVERSAL_APP/Contents/MacOS/"*.dylib; do
    dylib_name=$(basename "$dylib")
    arm64_dylib="$OUTPUT_DIR/arm64/${APP_NAME}.app/Contents/MacOS/$dylib_name"
    x86_dylib="$OUTPUT_DIR/x86_64/${APP_NAME}.app/Contents/MacOS/$dylib_name"
    if [ -f "$arm64_dylib" ] && [ -f "$x86_dylib" ]; then
        lipo -create "$arm64_dylib" "$x86_dylib" -output "$dylib"
        echo "  $dylib_name: universal"
    fi
done

# Update the bundled resources
cp "$DYLIB_SRC" "$UNIVERSAL_APP/Contents/Resources/libAntigravityTun.dylib"
cp "$PROXY_DIR/mitm_proxy" "$UNIVERSAL_APP/Contents/Resources/mitm_proxy"
cp "$PROXY_DIR/.env" "$UNIVERSAL_APP/Contents/Resources/.env"

# --- Step 5: Package ---
echo "[5/5] Creating DMG and ZIP..."
DMG_NAME="${APP_NAME}_${VERSION}-macos_x86_64_arm64.dmg"
ZIP_NAME="${APP_NAME}_${VERSION}-macos_x86_64_arm64.zip"

# Remove old packages
rm -f "$OUTPUT_DIR/$DMG_NAME" "$OUTPUT_DIR/$ZIP_NAME"

# Create DMG
hdiutil create -volname "${APP_NAME}" \
  -srcfolder "$UNIVERSAL_APP" \
  -ov -format UDZO \
  "$OUTPUT_DIR/$DMG_NAME" 2>&1 | tail -1

# Create ZIP
cd "$OUTPUT_DIR"
ditto -c -k --keepParent "${APP_NAME}.app" "$ZIP_NAME"

echo ""
echo "=== Done ==="
echo "  Universal binary: $(lipo -info "$UNIVERSAL_BIN")"
echo "  DMG: $OUTPUT_DIR/$DMG_NAME ($(du -sh "$OUTPUT_DIR/$DMG_NAME" | cut -f1))"
echo "  ZIP: $OUTPUT_DIR/$ZIP_NAME ($(du -sh "$OUTPUT_DIR/$ZIP_NAME" | cut -f1))"
echo "  Dylib: $(lipo -info "$DYLIB_SRC" | head -1)"
