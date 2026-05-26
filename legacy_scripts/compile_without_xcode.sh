#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DYLIB="$SCRIPT_DIR/libAntigravityTun.dylib"
LAUNCHER_RESOURCE_DYLIB="$REPO_ROOT/launcher/Resources/libAntigravityTun.dylib"

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

printf "%b\n" "[*] Compiling AntigravityTun Dylib using ${GREEN}clang++${NC} (Command Line Tools)..."

# 检查 clang 是否存在
if ! command -v clang++ >/dev/null 2>&1; then
    printf "%b\n" "${RED}[Error] clang++ not found. Please run 'xcode-select --install'${NC}"
    exit 1
fi

cd "$REPO_ROOT"

# 编译命令
# -std=c++17: 使用 C++17 标准
# -dynamiclib: 生成动态库
# -O3: 最高级优化
# -I ...: 头文件搜索路径
clang++ -std=c++17 -dynamiclib -O3 \
    -arch x86_64 -arch arm64 \
    -I AntigravityTun/AntigravityTun \
    AntigravityTun/AntigravityTun/AntigravityTun.cpp \
    -o "$TARGET_DYLIB"

if [ -f "$TARGET_DYLIB" ]; then
    mkdir -p "$(dirname "$LAUNCHER_RESOURCE_DYLIB")"
    cp -f "$TARGET_DYLIB" "$LAUNCHER_RESOURCE_DYLIB"
    printf "%b\n" "${GREEN}[Success] libAntigravityTun.dylib generated at: $TARGET_DYLIB${NC}"
    printf "%b\n" "${GREEN}[Sync] Copied to: $LAUNCHER_RESOURCE_DYLIB${NC}"
    echo
    echo "[Next] CLI 诊断命令:"
    echo "       cd \"$REPO_ROOT/launcher\" && swift run AntigravityProxyLauncher -- --doctor"
    echo
    echo "[Next] 以 .app 方式启动 GUI:"
    echo "       cd \"$REPO_ROOT/launcher\" && bash scripts/build_app_targets.sh"
    echo "       open \"$REPO_ROOT/launcher/.build/xcode/Build/Products/Debug/AntigravityProxyLauncher.app\""
else
    printf "%b\n" "${RED}[Fail] Build failed.${NC}"
    exit 1
fi
