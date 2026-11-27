import Foundation

/// 维护 `fake_ip.exclude_processes`：让指定应用在 dylib 侧跳过 FakeIP 改写。
///
/// 背景：dylib 用 FakeIP 把域名换成假地址，再在 `connect()` 里接管连接。这对
/// Electron（Antigravity / Antigravity IDE，Chromium 自带 socket 栈，调用来自
/// app 镜像）有效；但 Gemini 是原生 Swift + Network.framework，它的 gRPC 连接在
/// 框架内部建立，`connect()` 拦不到，FakeIP 只会让连接去拨一个不存在的地址，
/// 于是 iRPC 报 code=14、主窗口不显示。
///
/// 早期做法是「修复 Gemini 时把全局 fake_ip 关掉」——这会让共用同一份配置的
/// Antigravity / Antigravity IDE 一起失去隧道，属于跨应用回归。改为按进程排除后：
/// - 全局 `fake_ip.enabled` 始终为 true，其它应用行为零变化；
/// - 只有路径命中 `exclude_processes` 的进程（Gemini 主进程及其 helper）跳过改写。
///
/// 用路径子串而非 bundle id，是因为 helper 进程与主进程同属一个 `.app` 目录，一条
/// 标记就能覆盖它们，且 dylib 侧不需要读取 bundle id。
struct FakeIPBypassService {
    /// Gemini 的可执行路径标记（覆盖 `Gemini_Unlocked.app` 及其 helper）。
    private static let geminiMarkers = ["Gemini_Unlocked.app", "Gemini.app"]

    /// 修复/启动 Gemini 前调用：把 Gemini 加入排除名单，并确保全局 FakeIP 仍开启。
    static func applyForGemini() throws {
        try mutateConfig { root in
            var fakeIP = (root["fake_ip"] as? [String: Any]) ?? [:]
            // 兼容历史版本：0.0.x 曾把全局开关关掉，这里自愈回来
            fakeIP["enabled"] = true

            var excluded = Set((fakeIP["exclude_processes"] as? [String]) ?? [])
            for marker in geminiMarkers { excluded.insert(marker) }
            fakeIP["exclude_processes"] = excluded.sorted()
            root["fake_ip"] = fakeIP
        }
    }

    /// 修复/启动依赖隧道回连的目标（Antigravity / Antigravity IDE / CLI）前调用：
    /// 只确保全局 FakeIP 开启。
    ///
    /// 绝不能在这里清理排除名单：排除项是「按应用」的长期策略，若因启动
    /// Antigravity 就把 Gemini 从名单里删掉，用户之后双击 Gemini 会立刻退回
    /// FakeIP 死地址、窗口不显示。多应用共存时两者互不干扰才是正确语义。
    static func applyForTunnelApps() throws {
        try mutateConfig { root in
            var fakeIP = (root["fake_ip"] as? [String: Any]) ?? [:]
            // 兼容历史版本：曾被全局关掉过，这里自愈
            fakeIP["enabled"] = true
            root["fake_ip"] = fakeIP
        }
    }

    /// 当前配置里的排除名单（用于诊断页展示）
    static func excludedProcesses() -> [String] {
        guard
            let data = try? Data(contentsOf: FileSystemPaths.userProxyConfigFile),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let fakeIP = root["fake_ip"] as? [String: Any]
        else {
            return []
        }
        return (fakeIP["exclude_processes"] as? [String]) ?? []
    }

    // MARK: - 内部

    private static func mutateConfig(_ body: @escaping (inout [String: Any]) -> Void) throws {
        let url = FileSystemPaths.userProxyConfigFile
        let fm = FileManager.default

        try fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var root: [String: Any]
        if let data = try? Data(contentsOf: url),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = parsed
        } else if let template = try? Data(contentsOf: FileSystemPaths.bundledProxyConfigTemplate),
                  let parsed = (try? JSONSerialization.jsonObject(with: template)) as? [String: Any] {
            root = parsed
        } else {
            root = [
                "log_level": "warn",
                "dylib_log_enabled": false,
                "proxy": ["host": "127.0.0.1", "port": 7897, "type": "socks5"],
                "fake_ip": ["enabled": true, "cidr": "198.18.0.0/15"],
                "mitm": ["model_routing_enabled": true]
            ]
        }

        body(&root)

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
