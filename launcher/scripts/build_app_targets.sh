#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="$LAUNCHER_ROOT/.build/xcode"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is not installed"
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is not available"
  exit 1
fi

cd "$LAUNCHER_ROOT"

echo "[1/3] Generate Xcode project"
xcodegen generate >/dev/null

echo "[2/3] Build GUI app target"
xcodebuild \
  -project AntigravityProxyLauncher.xcodeproj \
  -scheme AntigravityProxyLauncher \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

echo "[3/3] Build CLI target"
xcodebuild \
  -project AntigravityProxyLauncher.xcodeproj \
  -scheme AntigravityProxyLauncherCLI \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/AntigravityProxyLauncher.app"
CLI_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/AntigravityProxyLauncherCLI"

echo "[4/4] Bundle Go MITM proxy"
MITM_PROXY_SRC="$(cd "$LAUNCHER_ROOT/../tools/mitm_proxy" && pwd)/mitm_proxy"
if [ -f "$MITM_PROXY_SRC" ]; then
  cp "$MITM_PROXY_SRC" "$APP_PATH/Contents/Resources/mitm_proxy"
  echo "  Bundled: $MITM_PROXY_SRC"
else
  echo "  WARNING: mitm_proxy binary not found at $MITM_PROXY_SRC, build it first"
fi

echo "done"
echo "app: $APP_PATH"
echo "cli: $CLI_PATH"
