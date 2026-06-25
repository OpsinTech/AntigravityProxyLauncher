# Antigravity Proxy Launcher (v2.5.0)

通过动态库（dylib）注入技术，对目标 AI 应用进行代理增强，实现跨应用、跨模型的网络流量拦截与转译。支持 macOS 原生桌面 GUI 操作。

> 已支持的应用：Antigravity、Antigravity IDE、Gemini、Agy CLI（Claude Code / Codex 随后版本支持）。

---

## 架构

| 组件 | 说明 |
|------|------|
| `AntigravityTun/` | C++ 动态库，通过 `DYLD_INSERT_LIBRARIES` 注入，拦截网络连接并路由至代理 / MITM |
| `launcher/` | SwiftUI 原生桌面 App，状态编排、GUI 面板、修复流程调度 |
| `tools/mitm_proxy/` | Go 代理，AI API 请求的中间人转译（Anthropic ↔ OpenAI / Gemini ↔ OpenAI） |
| `docs/` | 架构文档、构建指南、历史归档 |

---

## 功能概览

### 🖥️ 运行状态
应用总览与一键操作中心。切换不同目标应用，查看环境状态、代理连通性、模型映射状态。支持**修复**（注入 dylib）、**启动**、**关闭**、**清理环境**等操作。修复前自动校验代理连通性。

### ⚙️ 代理设置
全局代理配置页，所有应用共享。支持编辑/只读模式切换：
- SOCKS5/HTTP 代理节点配置（类型、主机、端口）
- 连通性检测（一键验证代理是否可达）
- 日志级别（error / warn / info / debug）
- 模型映射开关（控制 MITM 转译启停）
- FakeIP 开关与 CIDR 配置

### 🔀 模型映射
配置 AI 模型路由规则，将源模型请求转译到第三方兼容厂商。内置 DeepSeek、OfoxAI、CodeBuddy 三个厂商，支持测试连接和获取模型列表。可自定义源模型 → 目标厂商 + 目标模型的映射规则。**需要先在代理设置中开启模型映射开关。**

### 📊 配额管理
对接 Google OAuth，实时展示 API 流量配额使用情况与余量预警。

### 🔧 系统诊断
展示平台所有日志与配置文件的存储路径，支持复制路径和在 Finder 中定位。所有数据统一在 `~/.config/antigravity/`。

### ⚙️ 偏好设置
控制 App 自身行为：外观（隐藏 Dock 图标）、配额轮询、Google OAuth 凭据、更新检测、GitHub Token 等。

---

## 安装与运行

1. 下载 `.dmg`，拖入 `/Applications/`
2. 若提示"无法验证开发者"：
   ```bash
   xattr -cr /Applications/Antigravity\ Proxy\ Launcher.app
   ```
3. 双击运行

---

## 运行时数据

所有组件的日志和配置统一在 `~/.config/antigravity/`：

```
~/.config/antigravity/
├── proxy_config.json          # 代理配置（全局）
├── settings.json              # 偏好设置（全局）
├── model_routing.json         # 模型映射规则（全局）
├── goproxy_ca.pem             # MITM CA 证书
├── patch.log                  # 修复流程日志
├── mitm_proxy.log             # Go 代理日志
├── antigravity_proxy*.log     # dylib 运行日志
├── fakeip.lock                # FakeIP 锁文件
└── fakeip_map_<uid>.bin       # FakeIP 共享内存
```

---

## 二次开发

详见 [构建与分发指南](docs/app_build_distribution_guide.md)。

全量构建出包：
```bash
bash scripts/build_universal.sh
```

---

## 免责声明

本项目仅供技术研究和教育目的使用。使用者须遵守当地法律法规。使用此工具产生的任何后果由使用者自行承担。
