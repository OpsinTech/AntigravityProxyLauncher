#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="$LAUNCHER_ROOT/.build/xcode-release"
DIST_DIR="$LAUNCHER_ROOT/dist"
STAGING_DIR="$DIST_DIR/staging"
APP_NAME="AntigravityProxyLauncher"
APP_BUNDLE_NAME="$APP_NAME.app"
CLI_NAME="AntigravityProxyLauncherCLI"
VERSION_TAG="$(date +%Y%m%d-%H%M%S)"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is not installed"
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is not available"
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

cd "$LAUNCHER_ROOT"

echo "[1/5] Generate Xcode project"
xcodegen generate >/dev/null

echo "[2/5] Build GUI app (Release)"
xcodebuild \
  -project AntigravityProxyLauncher.xcodeproj \
  -scheme AntigravityProxyLauncher \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

echo "[3/5] Build CLI tool (Release)"
xcodebuild \
  -project AntigravityProxyLauncher.xcodeproj \
  -scheme AntigravityProxyLauncherCLI \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_BUNDLE_NAME"
CLI_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$CLI_NAME"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found at $APP_PATH"
  exit 1
fi

if [[ ! -f "$CLI_PATH" ]]; then
  echo "error: cli binary not found at $CLI_PATH"
  exit 1
fi

cp -R "$APP_PATH" "$STAGING_DIR/$APP_BUNDLE_NAME"
cp "$CLI_PATH" "$STAGING_DIR/$CLI_NAME"

ZIP_PATH="$DIST_DIR/Antigravity-Proxy-Launcher-macos-$VERSION_TAG.zip"
DMG_PATH="$DIST_DIR/Antigravity-Proxy-Launcher-macos-$VERSION_TAG.dmg"

rm -f "$ZIP_PATH" "$DMG_PATH"

echo "[4/5] Create ZIP artifact"
ditto -c -k --sequesterRsrc --keepParent "$STAGING_DIR/$APP_BUNDLE_NAME" "$ZIP_PATH"

echo "[5/5] Create DMG artifact"
hdiutil create \
  -volname "Antigravity Proxy Launcher" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

RELEASE_FEED_PATH=""
if [[ -n "${RELEASE_DOWNLOAD_BASE_URL:-}" ]]; then
  RELEASE_VERSION_VALUE="${RELEASE_VERSION:-$VERSION_TAG}"
  RELEASE_NOTES_VALUE="${RELEASE_NOTES:-}"
  RELEASE_DOWNLOAD_URL="${RELEASE_DOWNLOAD_BASE_URL%/}/$(basename "$DMG_PATH")"

  if [[ -x "$LAUNCHER_ROOT/scripts/generate_release_feed.sh" ]]; then
    echo "[optional] Generate release feed"
    bash "$LAUNCHER_ROOT/scripts/generate_release_feed.sh" \
      --version "$RELEASE_VERSION_VALUE" \
      --url "$RELEASE_DOWNLOAD_URL" \
      --notes "$RELEASE_NOTES_VALUE" \
      --output dist/release.json >/dev/null
    RELEASE_FEED_PATH="$DIST_DIR/release.json"
  fi
fi

rm -rf "$STAGING_DIR"

echo "done"
echo "zip: $ZIP_PATH"
echo "dmg: $DMG_PATH"
echo "app: $APP_PATH"
echo "cli: $CLI_PATH"
if [[ -n "$RELEASE_FEED_PATH" ]]; then
  echo "release feed: $RELEASE_FEED_PATH"
fi
