import Foundation
import Darwin

/// 用 LaunchAgent 托管 Go MITM 网关（18081）。
///
/// 之前网关是 Launcher 的子进程，`NSApplication.willTerminate` 会把它杀掉，
/// 于是用户一关 Launcher，Antigravity / IDE 里 Go 写的组件（language_server、agy）
/// 就因为没有代理全部断网。改成 launchd 托管后，Launcher 只承担控制面：
/// 关掉 Launcher 网关照常运行，崩溃由 KeepAlive 自愈，开机即生效，
/// 也不再有两个 Launcher 实例抢同一个端口的问题。
final class MitmProxyService {
    static let label = "com.antigravity.mitmproxy"
    static let port = 18081

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    private var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AntigravityProxy", isDirectory: true)
    }

    // MARK: - 状态

    /// launchd 层面的运行状态。
    func isRunning() -> Bool {
        let out = runLaunchctl(["print", "gui/\(getuid())/\(Self.label)"]) ?? ""
        return out.contains("state = running")
    }

    /// 网关是否在监听（比 launchd 状态更可靠：进程刚起来时 socket 可能还没 bind）。
    static func isPortListening() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // MARK: - 安装 / 启停

    /// 保证网关以给定参数运行。参数（含上游代理、模型路由开关）与已装 plist
    /// 不一致时会重载，因为 Go 网关只在启动时读一次这些值。
    ///
    /// - Returns: true 表示由 launchd 接管成功；false 表示应当退回 Launcher 直接 spawn。
    @discardableResult
    func ensureRunning(binary: String, environment: [String: String], keepAlive: Bool) -> Bool {
        do {
            let desired = try makePlistData(binary: binary, environment: environment, keepAlive: keepAlive)
            let existing = try? Data(contentsOf: plistURL)
            let changed = existing != desired

            if changed {
                try FileManager.default.createDirectory(
                    at: plistURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try desired.write(to: plistURL, options: .atomic)
            }

            let running = isRunning()
            if !changed && running { return true }

            _ = runLaunchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
            let status = runLaunchctlExitStatus(["bootstrap", "gui/\(getuid())", plistURL.path])
            guard status == 0 else {
                return false
            }
            // RunAtLoad=false 的 agent 在 bootstrap 时不会立刻起来（这正是「不常驻」
            // 模式的意图），但要现在能提供服务，仍需显式 kickstart 一次。
            _ = runLaunchctl(["kickstart", "gui/\(getuid())/\(Self.label)"])
            return true
        } catch {
            LauncherLogger.warn("MitmProxyService.ensureRunning failed: \(error.localizedDescription)")
            return false
        }
    }

    /// 重启（配置变更后调用）。
    func restart() -> Bool {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return false }
        let status = runLaunchctlExitStatus(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard status == 0 else { return false }
        _ = runLaunchctl(["kickstart", "gui/\(getuid())/\(Self.label)"])
        return true
    }

    /// 停止网关进程，保留 LaunchAgent 配置（下次 Launcher 启动或开机可按策略拉起）。
    func stop() {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
    }

    /// LaunchAgent 是否已安装（plist 是否存在）。
    func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 网关进程 PID（未运行时返回 nil）。
    func runningPID() -> Int? {
        guard let out = runLaunchctl(["print", "gui/\(getuid())/\(Self.label)"]) else { return nil }
        for line in out.split(separator: "\n") where line.contains("pid = ") {
            let digits = line.filter { $0.isNumber }
            if let pid = Int(digits), pid > 0 { return pid }
        }
        return nil
    }

    // MARK: - plist

    /// - Parameter keepAlive: true 时网关开机自启、崩溃自愈、退出 Launcher 后继续对外服务；
    ///   false 时只由 Launcher 显式 bootstrap，Launcher 退出即 bootout，不占用后台。
    private func makePlistData(binary: String, environment: [String: String], keepAlive: Bool) throws -> Data {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [binary],
            "WorkingDirectory": (binary as NSString).deletingLastPathComponent,
            "EnvironmentVariables": environment,
            "RunAtLoad": keepAlive,
            // 只在该退出属于「异常退出」时重启；用户/Launcher 主动 bootout 不触发。
            "KeepAlive": keepAlive ? ["SuccessfulExit": false] : false,
            "StandardOutPath": logDirectory.appendingPathComponent("mitm_proxy.out.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("mitm_proxy.err.log").path
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    // MARK: - launchctl

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private func runLaunchctlExitStatus(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
