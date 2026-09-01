# 故障排查：登录报 "Sorry, this account is ineligible to use Antigravity / not available in your location"

> **适用版本**：Antigravity Proxy Launcher v2.6.x（含 AntigravityTun dylib 注入版）
> **适用对象**：客服/技术支持（可直接把「第 3 节 客户自检命令」和第 4 节的对应分支转发给客户）
> **一句话结论**：这是 Antigravity 后端对**出口 IP 所在国家/地区**做的地区资格检查。只要「请求到底是从哪个 IP 出去的」落在不支持的地区，就会弹这个页面——与模型映射开关、API Key 是否填写**完全无关**。

---

## 1. 这个报错到底是什么意思

| 项目 | 说明 |
|---|---|
| 报错原文 | `Sorry, this account is ineligible to use Antigravity`<br>`Your current account is not eligible for Antigravity, because it is not currently available in your location.` |
| 判定方 | **Google 后端**（Antigravity 的后端接口，如 `cloudcode-pa.googleapis.com`），不是本地报错、不是网络断开 |
| 判定依据 | 请求**最终到达 Google 时的源 IP 所属国家/地区**是否在 Antigravity 开放地区列表内 |
| 发生时机 | 登录 / 首次请求时（在「换模型」之前），因此与模型映射无关 |
| 常见触发地区 | 中国大陆、香港、台湾等地通常不在开放列表；美/日/韩/欧洲等通常支持（以 Google 最新政策为准） |

**关键推论：客户能看到这个页面，本身就证明「请求已成功到达 Google」**——不是断网、不是连接被拒、不是证书问题。问题只在于「出去的那个 IP 的地区不对」。

---

## 2. 先理解本工具的工作方式（定位的前提，必读）

```
Antigravity 进程
    │  getaddrinfo("cloudcode-pa.googleapis.com")
    ▼   【dylib 拦截】→ 返回 FakeIP  198.18.x.x
    │  connect(198.18.x.x:443)
    ▼   【dylib 拦截】→ 把目标改写为 proxy_config.json 里的「本地端点」
    │                    （默认 socks5://127.0.0.1:7897）并做 SOCKS5 握手
    ▼
客户的本地代理客户端（Clash / ClashX / V2RayU / Shadowrocket …）
    │   以它自己「当前选中节点」的出口 IP 转发
    ▼
Google 后端 → 按出口 IP 的国家/地区判定 → 不在列表内就返回上面那个页面
```

由此得到两条**颠覆直觉**的结论，是整个定位的核心：

### 2.1 dylib 只认「配置文件里写死的本地端点」，不接管系统 VPN / TUN

- 改的是什么：`~/.config/antigravity/proxy_config.json` 里的 `proxy.host` / `proxy.port` / `proxy.type`（默认值 `127.0.0.1` / `7897` / `socks5`，见 [AntigravityTun/Config.hpp](../AntigravityTun/AntigravityTun/Config.hpp)）。
- 因此「客户换了 N 个 VPN」**不一定改变结果**：只要当时监听在那个端口上的进程没变（旧客户端残留、新客户端端口不同、新客户端是 TUN 模式没有本地端口），请求就还是走老路子出去。

### 2.2 Launcher 的「代理检测通过」证明的东西非常有限

[ProxyConnectivityService.swift](../launcher/Sources/Services/ProxyConnectivityService.swift) 的 `probe()` 只做两件事：

1. TCP 连上 `host:port`；
2. SOCKS5 方法协商握手（`0x05,0x01,0x00` → 期待 `0x05,0x00`）。

也就是说「检测通过」= **当时有个进程在该端口监听，且它会说 SOCKS5 协议**。它**不验证**：

- ❌ 能否真正转发数据（没发过任何一条 CONNECT 请求）
- ❌ **出口 IP 在哪个国家**（地区问题完全测不出来）
- ❌ 监听者是哪个客户端（残留的旧 Clash 同样能通过检测）

> 结论：一个「出口在香港/台湾的旧实例」占着 7897 端口，检测照样打勾。**检测结果与所有嫌疑分支都不矛盾，不能用来排除地区问题。**

---

## 3. 定位方法论：四步裁决法

### Step 0（前置） 打开 Info 级日志，并且**用 Launcher 启动**

1. 编辑 `~/.config/antigravity/proxy_config.json`，把 `log_level` 改成 `info`（要更细的握手细节用 `debug`）：

   ```json
   { "log_level": "info", "proxy": { "host": "127.0.0.1", "port": 7897, "type": "socks5" } }
   ```

2. **必须通过 Launcher 的「启动应用」按钮启动**：Launcher 会给目标进程注入 `ANTIGRAVITY_LOG_FILE=1` + `ANTIGRAVITY_LOG_LEVEL`（见 [LaunchService.swift:104-107](../launcher/Sources/Services/LaunchService.swift#L104)）。
   ⚠️ 直接双击 `Antigravity_Unlocked.app` 启动的话，dylib **不会写日志文件**（输出只到 stderr，不可见）。
3. 复现问题后，日志在 `~/.config/antigravity/` 下：`antigravity_proxy.log`、`antigravity_proxy_loader.log`（按进程首次命中的 hook 分流，两个文件都要看；若存在 `antigravity_proxy.<pid>.log` 也一并收）。
4. 每次改完配置必须**完全退出并重启 Antigravity**（dylib 每个进程只加载配置一次）。

---

### Step 1 命令 A/B：谁在监听这个端口？它的出口是哪国？

```bash
# A. 到底是谁在监听 7897？（客户以为在用的 VPN，未必是它）
sudo lsof -nP -iTCP:7897 -sTCP:LISTEN

# B. 这个端点真正的出口国家/地区（= dylib 视角的实际出口）
curl -s --socks5-hostname 127.0.0.1:7897 https://ipinfo.io/json | grep -E '"country"|"org"'

# C. 对照：本机直连的出口
curl -s https://ipinfo.io/json | grep country
```

| 观察结果 | 判读 |
|---|---|
| A 查出的进程 ≠ 客户当前在用的 VPN | **典型根因 B**：端口被残留的旧客户端占着，或新客户端不在 7897。换 VPN 毫无作用 |
| A 无任何输出（没人监听） | 该端口上没有 SOCKS5 服务（客户是 TUN 模式 / 客户端没开本地代理）→ 根因 D |
| B 的 `country` 是 CN/HK/TW 等不支持地区 | **典型根因 A**：出口节点地区不对 |
| B 的 `country` 是支持地区 | 排除出口地区问题 → 继续 Step 2/3（很可能是主进程没注入，流量直连） |

---

### Step 2 命令 C：dylib 到底注入进了哪些进程？

注入机制（[PatchService.swift:318-334](../launcher/Sources/Services/PatchService.swift#L318)）：只改写**主 App** 的 `Contents/Info.plist`，写入 `LSEnvironment.DYLD_INSERT_LIBRARIES`；Helper 子进程靠从主进程 fork/exec **继承环境变量**加载（dylib 因此被镜像进每个 Helper 的 Resources）。

```bash
# 列出所有 Antigravity 相关进程
ps aux | grep -i antigravity | grep -v grep

# 逐个进程检查 dylib 是否加载（把 <PID> 换成上一步拿到的 PID）
sudo vmmap <PID> | grep -i AntigravityTun
# 或：lsof -p <PID> | grep -i AntigravityTun
```

- **主进程**（路径形如 `.../Antigravity_Unlocked.app/Contents/MacOS/Antigravity`，不带 `Helper`）**必须有输出**。
- 主进程无输出 ⇒ **根因 C**：Electron 的登录/资格检查跑在主进程，它的流量**从客户真实 IP 直连**，无论换什么（代理模式）VPN 都不会变；而你本地没问题，是因为你自己的直连 IP 本来就在支持地区——这类问题本地永远复现不出来。

> 注：日志里 `Failed to open config file` 这类 WARN 行的候选路径里，含 `Frameworks/Antigravity Helper.app/...` 的是 Helper 进程写的、含 `Antigravity_Unlocked.app/Contents/Resources/...` 的才是主进程写的。**若日志里只有 Helper 的行、没有主进程的行，同样指向根因 C**（前提是已经按 Step 0 通过 Launcher 启动了）。

---

### Step 3 命令 D：hook 日志——流量到底有没有走代理

在 `~/.config/antigravity/antigravity_proxy*.log` 里按 **[pid]** 区分进程（配合 Step 2 的 PID 对照主/Helper），重点看这几类行：

| 日志行（Info/Debug 级） | 含义 |
|---|---|
| `Hook: getaddrinfo mapped cloudcode-pa.googleapis.com -> 198.18.x.x` | 该进程的域名→FakeIP 映射生效 |
| `SOCKS5 tunnel established to cloudcode-pa.googleapis.com:443` | ✅ **完整走通本地端点**（地区问题就只剩 Step 1 的出口国家） |
| `Failed to connect to proxy, fd=..., errno=61` | 该端口当时没有服务（errno 61 = ECONNREFUSED）→ 根因 B/D |
| `SOCKS5 Handshake failed, fd=..., domain=...` | 端口上有东西但**不是合规 SOCKS5**（例如 HTTP 代理占用，需要把 `type` 改成 `http`）→ 根因 B |
| `MITM CONNECT fail ...` | 仅当开启模型映射后才出现，与本报错无关 |
| 完全没有 `googleapis.com` / `accounts.google.com` 的映射行 | 该进程的请求没被 hook（主进程无映射 ⇒ 根因 C） |

---

### 4. 裁决矩阵（把上面四步的结果对号入座）

| Step1 出口国家 | Step2 主进程注入 | Step3 日志证据 | 结论 | 处理 |
|---|---|---|---|---|
| 不支持地区 | 已注入 | 有 tunnel established | **根因 A：出口节点地区不对** | 换到支持地区的节点；或杀掉占用 7897 的残留进程，把配置指向正确的客户端。改完用 B 命令复验 country |
| 支持地区 | **未注入** | 主进程无任何映射行 | **根因 C：主进程流量直连** | 见 5.3（清理 LS 缓存 / 确认启动的是修复版） |
| 支持地区 | 已注入 | 有 tunnel、仍报错 | 地区与代理均正常 → 可能是账号/企业策略问题 | 换一个 Google 账号测试；仍不行请回传完整日志 |
| （端口没人听 / 握手失败） | 已注入 | `errno=61` 或 `Handshake failed` | **根因 B/D：本地端点配置与实际不符** | 见 5.2/5.4（改 host/port/type 后重启应用） |

---

## 5. 各根因的修法

### 5.1 根因 A：出口节点地区不受支持（最常见）

1. 用 Step 1 的 B 命令确认 `country`。
2. 把代理客户端切到**受支持地区**的节点（美/日/韩/欧等）。注意：很多标着「海外」的节点实际在港/台机房，Google AI 系产品通常不支持——这正是「换了还报同样错」的高频原因。
3. 注意「改的是当时占用该端口的客户端」，不是客户手头刚装的那个。
4. 复验：`curl -s --socks5-hostname 127.0.0.1:7897 https://ipinfo.io/json | grep country`，确认已变为支持地区后再重启 Antigravity。

### 5.2 根因 B：本地端点（host/port/type）与实际不符

常见端口对照：**ClashX 默认 7890**、Clash 混合端口常为 7890、V2RayU/Shadowrocket 各不相同。

1. `lsof -nP -iTCP -sTCP:LISTEN | grep -E "7890|7897|1080|1087|20171"` 找出客户客户端**真实监听**的端口。
2. 在 Launcher → **代理配置 (Proxy Config)** 里把 Host / Port / Type 改成实际值（HTTP 代理选 `http`，不是 `socks5`）。
3. 保存后会写入 `~/.config/antigravity/proxy_config.json`；**重启 Antigravity** 生效。
4. 点一次「测试连接」，再用 Step 1 的 B 命令验证出口国家。

### 5.3 根因 C：主进程未注入（流量直连）

症状：`vmmap` 主进程无 `AntigravityTun`；日志里只有 Helper 的行。

1. 确认启动的是修复版：`~/Applications/Antigravity_Unlocked.app`（而不是 `~/Downloads` 里的旧副本或原版 `/Applications/Antigravity.app`）。
2. 清隔离属性并重注册 LaunchServices（解决「Info.plist 的 LSEnvironment 未生效」）：

   ```bash
   xattr -cr ~/Applications/Antigravity_Unlocked.app
   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u ~/Applications/Antigravity_Unlocked.app
   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Antigravity_Unlocked.app
   ```

3. 仍不行 → 在 Launcher 里执行一次「清理环境 + 重新修复」，然后 **用 Launcher 的「启动应用」按钮启动**（不要双击）。
4. 复验：`vmmap 主进程PID | grep AntigravityTun` 必须有输出。

### 5.4 根因 D：VPN 只有 TUN / 系统级模式，没有本地代理端口

本工具**不支持直接接管 TUN 全局隧道**——它必须指向一个本机 SOCKS5 / HTTP 代理端口。

- 方案一：在该客户端里打开「本地 SOCKS5 / HTTP 代理」或「允许局域网连接」之类的选项，拿到本地端口后按 5.2 配置。
- 方案二：改用 Clash 类并开启混合端口（mixed port），再按 5.2 配置。

### 5.5 附：`Failed to open config file` 这条 WARN 要不要管

出现在 `antigravity_proxy_loader.log`，说明当时 `~/.config/antigravity/proxy_config.json` 不存在，dylib 使用默认值（`socks5 127.0.0.1:7897` + fake_ip 开启）。**默认行为与显式配置一致，通常不是致命的**；但会让日志级别退化为默认 `warn`（[Logger.hpp:196](../AntigravityTun/AntigravityTun/Logger.hpp#L196)），导致看不到映射/隧道的 Info 行。建议始终保留 Launcher 生成的配置文件。

---

## 6. 仍未解决时，请客户回传「日志包」

请把 `~/.config/antigravity/` 下这些文件**全部打包**回传（缺一样都会拖慢定位）：

1. `proxy_config.json`（当前代理配置）
2. `model_routing.json`（模型映射配置）
3. `antigravity_proxy.log`、`antigravity_proxy_loader.log`、`antigravity_proxy.<pid>.log`（**关键证据**，需按 Step 0 用 Launcher 以 `info` 级复现后再拷）
4. `mitm_proxy.log`（Go 代理日志；未开启模型映射时应为 passthrough 模式，属正常）
5. `patch.log`、以及 Launcher 打包好的诊断日志

再加以下**命令输出**（直接贴文本）：

```bash
lsof -nP -iTCP:7897 -sTCP:LISTEN
curl -s --socks5-hostname 127.0.0.1:7897 https://ipinfo.io/json
curl -s https://ipinfo.io/json
ps aux | grep -i antigravity | grep -v grep
sudo vmmap <主进程PID> | grep -i AntigravityTun
sw_vers          # macOS 版本
```

并注明：Launcher 版本、Antigravity 版本、所在国家/地区、使用的代理客户端与节点地区。

---

## 附录：为什么「模型映射没开」与这个报错无关

- 模型映射（`mitm.model_routing_enabled` + 路由规则）只做一件事：把 **5 个 AI 域名**（`anthropic.com` / `deepseek.com` / `generativelanguage.googleapis.com` / `cloudcode-pa.googleapis.com` / `openai.com`，见 [AntigravityTun.cpp:95-101](../AntigravityTun/AntigravityTun/AntigravityTun.cpp#L95)）的**聊天补全请求**转发给第三方厂商——发生在登录之后的对话阶段。
- 而本文的报错是**登录时的地区资格检查**，发生在任何对话之前。
- 因此：映射全开，出口地区不对 → 照样弹这个页面；映射全关，出口地区正确 → 登录完全正常（只是不替换模型）。
- 反过来，如果客户的 `model_routing.json` 里所有 provider 都是 `enabled: false` 且 API Key 为空，那么即使登录成功，模型映射也是不生效的——这是**另一个**待办事项，与本报错无关，需在登录问题解决后再单独配置。
