# Antigravity Proxy Launcher (v2.5.0)

让 Antigravity / Gemini 桌面应用走自定义代理，支持 AI 模型 API 跨厂商转译。

> 已支持：Antigravity、Antigravity IDE、Gemini、Agy CLI（Claude Code / Codex 随后版本）

---

## 解决了什么问题

| 痛点 | 解决方案 |
|------|---------|
| Antigravity / Gemini 桌面版不走系统代理 | dylib 注入，强制所有流量走 SOCKS5/HTTP 代理 |
| Claude API 太贵，想换成 DeepSeek | MITM 代理截获 API 请求，按规则转译到指定厂商 |
| 手动编辑配置文件太麻烦 | 原生 macOS GUI，所见即所得 |
| 查配额要上网页 | 内置 OAuth 登录，实时展示各模型余量 |

---

## 快速开始

1. **下载** `.dmg` → 拖入 `/Applications/`
2. **打开**前确认代理客户端（Clash / Mihomo）已在运行
3. 进入**代理设置** → 确认节点 → 点击**检测**确认连通
4. 回到**运行状态** → 选目标应用 → 点击**修复**
5. 修复完成后点击**启动**

> 首次打开若提示"无法验证开发者"：`xattr -cr /Applications/Antigravity\ Proxy\ Launcher.app`

---

## 📖 操作文档

每个功能的详细操作步骤、截图、FAQ → **[GitHub Wiki](https://github.com/OpsinTech/AntigravityProxyLauncher/wiki)**

---

## 功能概览

| 标签页 | 说明 |
|--------|------|
| 运行状态 | 应用总览，一键修复/启动/关闭 |
| 代理设置 | 全局代理节点配置、连通性检测、日志级别、模型映射开关 |
| 模型映射 | AI API 跨厂商转译规则（内置 DeepSeek / OfoxAI / CodeBuddy） |
| 配额管理 | Google OAuth 登录，实时配额看板 |
| 系统诊断 | 所有日志和配置文件路径一览，支持复制/Finder 定位 |
| 偏好设置 | 外观、配额轮询、OAuth 凭据、更新检测 |

---

## 运行时数据

所有文件统一在 `~/.config/antigravity/`：

```
~/.config/antigravity/
├── proxy_config.json          # 代理配置（全局）
├── settings.json              # 偏好设置（全局）
├── model_routing.json         # 模型映射规则（全局）
├── patch.log                  # 修复日志
├── mitm_proxy.log             # Go 代理日志
├── antigravity_proxy*.log     # dylib 日志
└── ...
```

---

## 二次开发

```bash
bash scripts/build_universal.sh
```

详见 [构建与分发指南](docs/app_build_distribution_guide.md)。

---

## 免责声明

本项目仅供技术研究和教育目的使用。使用此工具产生的任何后果由使用者自行承担。
