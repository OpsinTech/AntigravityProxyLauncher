#!/usr/bin/env bash
set -euo pipefail

# create_dmg.sh — 生成带版式、可拖拽安装的 DMG（零依赖）
#
# 产出标准「拖拽安装」DMG：挂载后 Finder 窗口左侧是 App，右侧是
# Applications 文件夹别名，用户把 App 拖到别名即完成安装。
#
# 用法:
#   create_dmg.sh <app_path> <volume_name> <output_dmg_path>
#
# 依赖（本机自带，无需联网安装）:
#   hdiutil, osascript (Finder), python3 (仅用标准库画背景图)

usage() {
  echo "Usage: $0 <app_path> <volume_name> <output_dmg_path>" >&2
  exit 1
}

APP_PATH="${1:-}"
VOL_NAME="${2:-}"
DMG_PATH="${3:-}"

[ -z "$APP_PATH" ] && usage
[ -z "$VOL_NAME" ] && usage
[ -z "$DMG_PATH" ] && usage
[ -d "$APP_PATH" ] || { echo "error: app bundle not found: $APP_PATH" >&2; exit 1; }
command -v hdiutil  >/dev/null 2>&1 || { echo "error: hdiutil not available" >&2; exit 1; }
command -v osascript >/dev/null 2>&1 || { echo "error: osascript not available" >&2; exit 1; }

# 解析为绝对路径
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
DMG_DIR="$(cd "$(dirname "$DMG_PATH")" && pwd)"
DMG_PATH="$DMG_DIR/$(basename "$DMG_PATH")"
APP_NAME="$(basename "$APP_PATH")"

echo "=== create_dmg: $APP_NAME -> $DMG_PATH ==="

# 临时工作区
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

STAGING="$TMP_DIR/staging"
RW_DMG="$TMP_DIR/rw.dmg"
MNTPOINT="$TMP_DIR/mount"
mkdir -p "$STAGING" "$MNTPOINT"

# 1) 拷贝 .app
cp -R "$APP_PATH" "$STAGING/$APP_NAME"

# 2) Applications 别名（symlink 到 /Applications），实现拖拽安装
ln -s /Applications "$STAGING/Applications"

# 3) 背景图（深色渐变，python3 标准库生成，无额外依赖）
BG_PNG="$TMP_DIR/background.png"
python3 - "$BG_PNG" <<'PY'
import sys, struct, zlib

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data +
            struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

def write_png(path, w, h, px):
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type 0 (None)
        raw.extend(px[y*w*3:(y+1)*w*3])
    sig = b'\x89PNG\r\n\x1a\n'
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)  # 8-bit RGB
    idat = zlib.compress(bytes(raw), 9)
    with open(path, 'wb') as f:
        f.write(sig)
        f.write(chunk(b'IHDR', ihdr))
        f.write(chunk(b'IDAT', idat))
        f.write(chunk(b'IEND', b''))

w, h = 640, 400
top = (42, 45, 52)
bot = (22, 24, 28)
buf = bytearray()
for y in range(h):
    t = y / max(1, h - 1)
    r = int(top[0] * (1 - t) + bot[0] * t)
    g = int(top[1] * (1 - t) + bot[1] * t)
    b = int(top[2] * (1 - t) + bot[2] * t)
    buf.extend(bytes((r, g, b)) * w)
write_png(sys.argv[1], w, h, bytes(buf))
print("background:", sys.argv[1])
PY
mkdir -p "$STAGING/.background"
cp "$BG_PNG" "$STAGING/.background/background.png"

# 4) 生成可读写 DMG（HFS+ 对窗口版式最稳定）
echo "[1/4] create RW DMG..."
hdiutil create -volname "$VOL_NAME" \
  -srcfolder "$STAGING" \
  -format UDRW \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  "$RW_DMG" 2>&1 | tail -1 || {
    echo "error: hdiutil create failed" >&2; exit 1; }

# 5) 挂载并应用 Finder 窗口版式（带硬超时，避免构建挂起）
echo "[2/4] mount & style window..."
hdiutil attach -nobrowse -noautoopen -mountpoint "$MNTPOINT" "$RW_DMG" >/dev/null

set +e
# 硬超时包裹：若 GUI/osascript 在超时内未完成（如无交互环境），
# 直接跳过，但仍保留 Applications 别名，DMG 可正常使用（拖拽安装不受影响）。
STYLE_TIMEOUT=25
if command -v gtimeout >/dev/null 2>&1; then
  STYLE_PREFIX="gtimeout $STYLE_TIMEOUT"
elif command -v timeout >/dev/null 2>&1; then
  STYLE_PREFIX="timeout $STYLE_TIMEOUT"
else
  STYLE_PREFIX=""
fi

$STYLE_PREFIX osascript <<EOF
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 200, 1040, 640}
    set viewOptions to the icon view options of container window
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set arrangement of viewOptions to not arranged
    set background picture of viewOptions to POSIX file "$MNTPOINT/.background/background.png"
    set position of item "$APP_NAME" of container window to {160, 250}
    set position of item "Applications" of container window to {480, 250}
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF
STYLE_RC=$?
set -e

if [ "$STYLE_RC" -ne 0 ]; then
  echo "warning: Finder window styling failed/timed out (rc=$STYLE_RC); DMG still usable (no styled window, drag-to-install works)."
fi

# 让 .DS_Store 落盘并卸载
chmod -Rf go-w "$MNTPOINT" 2>/dev/null || true
sync
hdiutil detach "$MNTPOINT" >/dev/null 2>&1 || hdiutil detach -force "$MNTPOINT" >/dev/null 2>&1 || true

# 6) 压缩为只读最终 DMG
echo "[3/4] compress to final DMG..."
rm -f "$DMG_PATH"
hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" 2>&1 | tail -1

# 7) 校验
echo "[4/4] verify..."
if [ ! -f "$DMG_PATH" ]; then
  echo "error: final DMG not created" >&2; exit 1
fi
echo "  DMG: $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
echo "done"
