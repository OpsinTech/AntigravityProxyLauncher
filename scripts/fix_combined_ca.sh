#!/usr/bin/env bash
#
# fix_combined_ca.sh
# ----------------------------------------------------------------------------
# 用于修复 Antigravity Proxy Launcher 在部分 macOS 上出现的
#   tls: failed to verify certificate: x509: certificate signed by unknown authority
# 错误（典型表现：目标 App 内的 Go 代理请求 oauth2.googleapis.com 失败）。
#
# 根因：Launcher 给目标 App 注入 SSL_CERT_FILE 指向 combined_ca.pem。该变量会
# *完全替换* Go 的信任库（非追加），因此该文件必须同时包含「系统根 CA」和
# 「goproxy 自签 CA」。若文件缺失 / 不完整（只有 goproxy CA），真实 HTTPS 验签
# 就会失败。本脚本在其机器上重新生成一个「针对其系统」的完整包。
#
# 用法：
#   chmod +x fix_combined_ca.sh
#   ./fix_combined_ca.sh
# 然后完全退出 Launcher 与目标 App，重新启动即可。
# ----------------------------------------------------------------------------

set -u

CONFIG_DIR="$HOME/.config/antigravity"
GOPROXY_CA="$CONFIG_DIR/goproxy_ca.pem"
COMBINED_CA="$CONFIG_DIR/combined_ca.pem"

# 终端颜色
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; NC=""
fi

info()  { echo "${CYAN}[*]${NC} $*"; }
ok()    { echo "${GREEN}[✓]${NC} $*"; }
warn()  { echo "${YELLOW}[!]${NC} $*"; }
err()   { echo "${RED}[✗]${NC} $*"; }
step()  { echo "${BOLD}==> $*${NC}"; }

count_certs() {
  # $1 = pem 文件路径；输出 BEGIN CERTIFICATE 出现的次数
  [ -f "$1" ] || { echo 0; return; }
  grep -c "BEGIN CERTIFICATE" "$1" 2>/dev/null || echo 0
}

step "1/4  检查 goproxy 自签 CA"
if [ ! -f "$GOPROXY_CA" ]; then
  err "未找到 $GOPROXY_CA"
  err "说明 Launcher 尚未生成过 MITM CA。请先正常启动一次 Launcher（让它导出 goproxy_ca.pem），"
  err "然后关闭 Launcher 与目标 App，再重新运行本脚本。"
  exit 1
fi
ok "goproxy_ca.pem 存在 ($(wc -c < "$GOPROXY_CA") bytes, $(count_certs "$GOPROXY_CA") cert)"

step "2/4  收集系统根 CA（多源兜底）"
SYSTEM_ROOTS=""
SRC=""

# 源 1：/etc/ssl/cert.pem（Homebrew / Xcode CLT）
if [ -f /etc/ssl/cert.pem ] && [ -s /etc/ssl/cert.pem ]; then
  SYSTEM_ROOTS="$(cat /etc/ssl/cert.pem)"
  SRC="/etc/ssl/cert.pem"
fi

# 源 2：系统钥匙串（每台 Mac 都有，干净与否均可）
if [ -z "$SYSTEM_ROOTS" ]; then
  if OUT=$(/usr/bin/security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain 2>/dev/null); then
    if [ -n "$OUT" ]; then SYSTEM_ROOTS="$OUT"; SRC="SystemRootCertificates.keychain"; fi
  fi
fi

# 源 3：用户 login.keychain（企业/自装根证书）
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
if [ ! -z "$SYSTEM_ROOTS" ]; then
  # 即使已有系统根，也尝试补充 login 里的用户自装根
  if OUT=$(/usr/bin/security find-certificate -a -p "$LOGIN_KC" 2>/dev/null); then
    if [ -n "$OUT" ]; then SYSTEM_ROOTS="$SYSTEM_ROOTS"$'\n'"$OUT"; SRC="$SRC + login.keychain-db"; fi
  fi
else
  if OUT=$(/usr/bin/security find-certificate -a -p "$LOGIN_KC" 2>/dev/null); then
    if [ -n "$OUT" ]; then SYSTEM_ROOTS="$OUT"; SRC="login.keychain-db"; fi
  fi
fi

if [ -z "$SYSTEM_ROOTS" ]; then
  err "无法从任何来源获取系统根 CA。"
  err "建议安装 Xcode Command Line Tools（提供 /etc/ssl/cert.pem）："
  err "    xcode-select --install"
  err "安装完成后重新运行本脚本。"
  exit 2
else
  ROOT_COUNT=$(printf '%s\n' "$SYSTEM_ROOTS" | grep -c "BEGIN CERTIFICATE")
  ok "系统根 CA 已获取，来源: $SRC (约 $ROOT_COUNT 张)"
fi

step "3/4  重建 combined_ca.pem"
# 备份旧文件（若有）
if [ -f "$COMBINED_CA" ]; then
  BACKUP="$COMBINED_CA.bak.$(date +%Y%m%d%H%M%S)"
  cp "$COMBINED_CA" "$BACKUP"
  info "已备份旧 combined_ca.pem -> $BACKUP"
fi

{
  printf '%s\n' "$SYSTEM_ROOTS"
  cat "$GOPROXY_CA"
} > "$COMBINED_CA"

TOTAL=$(count_certs "$COMBINED_CA")
if [ "$TOTAL" -lt 2 ]; then
  err "重建失败：合并后证书数=$TOTAL（应 >= 2）。请检查上面的来源输出。"
  exit 3
fi
ok "已写入 $COMBINED_CA ($(wc -c < "$COMBINED_CA") bytes, 共 $TOTAL 张证书)"

step "4/4  完成"
echo
ok "${BOLD}完整证书包已生成。${NC}"
echo "   路径: $COMBINED_CA"
echo
warn "请现在："
warn "  1) 完全退出 Launcher（菜单退出 / 活动监视器结束进程）"
warn "  2) 完全退出被 patch 的目标 App"
warn "  3) 重新启动 Launcher 再启动目标 App"
echo
info "若仍报错，请把 Launcher / mitm_proxy 日志中带 '[Launch] Combined CA' 或"
info "'SSL_CERT_FILE' 的行发给开发者排查。"
exit 0
