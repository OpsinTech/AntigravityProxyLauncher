import Foundation
import AppKit
import Darwin

class ProxyManager {
    static let shared = ProxyManager()

    private let proxyPort = 18081
    private var process: Process?
    /// True while we deliberately stop the child (restart, app quit) so its
    /// exit handler does not mistake that exit for a crash.
    private var isIntentionalStop = false
    private var isTerminating = false
    /// true 表示网关由 launchd 托管（LaunchAgent），而不是本进程的子进程。
    private var isGatewayManaged = false

    /// Startup-only values the live process was launched with. The Go gateway
    /// reads them exactly once, so they define what "currently applied" means.
    private var activeEndpoint: String?
    private var activeModelRouting: Bool?

    /// Consecutive crash restarts; reset once the gateway answers a health check.
    private var restartAttempt = 0
    private var pendingRestart: DispatchWorkItem?
    private var isStarting = false

    /// Serial queue for the slow parts (terminating, reclaiming 18081, waiting
    /// for the port to be released) so the main thread never blocks on restart.
    private let controlQueue = DispatchQueue(label: "io.antigravity.proxy.control", qos: .userInitiated)

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isTerminating = true
            // 行为由「退出后保留网关」开关决定：
            //  - 打开：网关交给 launchd 常驻，可继续对外提供模型服务；
            //  - 关闭：网关随 Launcher 一起停止（LaunchAgent 配置保留，下次启动自动拉起）。
            let keepAlive = (try? AppSettingsService().load())?.keepGatewayAlive ?? true
            self?.stopProxy(terminateGateway: !keepAlive)
        }
    }

    // MARK: - Lifecycle

    func startProxy() {
        guard process == nil, !isStarting, pendingRestart == nil else { return }

        // Two launcher instances would fight over 18081: each one reclaims the
        // port and kills the other's gateway. Defer until we are the only one
        // left (the backoff scheduler re-checks).
        if Self.runningInstanceCount() > 1 {
            LauncherLogger.warn("Another AntigravityProxyLauncher instance is running; deferring proxy start")
            scheduleAutoRestart(reason: "another launcher instance is running")
            return
        }

        isStarting = true

        controlQueue.async { [weak self] in
            guard let self else { return }
            // 如果网关已经由 launchd 托管并在运行，绝对不能先 reclaimProxyPort()：
            // 那会把后台常驻的进程 SIGTERM 掉，用户只是重新打开 Launcher 看一眼界面，
            // Antigravity / IDE 正在跑的 SSE 长连接就被切断；ensureRunning() 的
            // 「plist 没变就复用」快速路径也永远命中不了。
            // 只有 launchd 没跑、而 18081 被上一次崩溃留下的孤儿进程占着时才回收。
            if !MitmProxyService().isRunning() {
                self.reclaimProxyPort()
            }

            DispatchQueue.main.async {
                self.isStarting = false
                guard !self.isTerminating else { return }
                self.launchProxy()
            }
        }
    }

    func restartProxy() {
        restartProxy(reason: nil, completion: nil)
    }

    /// Restarts the gateway off the main thread. `completion` runs on the main
    /// queue once the new process has been spawned (or the start failed).
    func restartProxy(reason: String?, completion: (() -> Void)?) {
        guard !isStarting else { return }
        if let reason {
            LauncherLogger.info("Restarting Go MITM Proxy: \(reason)")
        }

        if isGatewayManaged {
            pendingRestart?.cancel()
            pendingRestart = nil
            controlQueue.async { [weak self] in
                guard let self else { return }
                // 必须先 bootout 再起：KeepAlive 开着时 launchd 会在进程退出的瞬间
                // 把它拉回来，与后面的 bootout 抢同一个 pid。
                // 而且不能只 restart()：那样只会重新 bootstrap 旧 plist，
                // 改过的上游代理 / keep_alive 策略不会写入，重启后仍跑旧参数。
                MitmProxyService().stop()
                self.reclaimProxyPort()

                DispatchQueue.main.async {
                    guard !self.isTerminating else { return }
                    self.isGatewayManaged = false
                    self.activeEndpoint = nil
                    self.activeModelRouting = nil
                    // launchProxy → ensureRunning 会用最新环境与 keepAlive 重写 plist，
                    // 并刷新 activeEndpoint / activeModelRouting。
                    self.launchProxy()
                    completion?()
                }
            }
            return
        }

        isIntentionalStop = true
        pendingRestart?.cancel()
        pendingRestart = nil

        let owned = process
        process = nil
        activeEndpoint = nil
        activeModelRouting = nil

        controlQueue.async { [weak self] in
            guard let self else { return }
            self.terminateAndWait(owned)
            self.reclaimProxyPort()

            DispatchQueue.main.async {
                self.isIntentionalStop = false
                guard !self.isTerminating else { return }
                self.launchProxy()
                completion?()
            }
        }
    }

    func stopProxy(terminateGateway: Bool = true) {
        isIntentionalStop = true
        pendingRestart?.cancel()
        pendingRestart = nil

        if isGatewayManaged {
            if terminateGateway {
                MitmProxyService().stop()
                isGatewayManaged = false
            }
            activeEndpoint = nil
            activeModelRouting = nil
            return
        }

        let owned = process
        process = nil
        if let p = owned, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
            }
        }

        activeEndpoint = nil
        activeModelRouting = nil
        LauncherLogger.info("Go MITM Proxy stopped")
    }

    // MARK: - Runtime config drift

    /// Identity of an upstream proxy endpoint. The gateway treats the endpoint
    /// as immutable for its lifetime, so string equality is the right check for
    /// "does the running process still match the saved config?".
    static func endpointDescription(for config: ProxyConfig) -> String {
        let type = config.proxy.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(type)://\(config.proxy.host):\(config.proxy.port)"
    }

    /// Number of copies of this app currently running (>= 1 when called from a
    /// live instance). Used to avoid two launchers fighting over port 18081.
    private static func runningInstanceCount() -> Int {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return 1 }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count
    }

    /// Restarts the gateway when a startup-only setting differs from the one the
    /// running process was launched with: the upstream endpoint or
    /// `mitm.model_routing_enabled`. Without this, saving a new port (or the
    /// routing switch) silently kept the old behaviour — every request then
    /// surfaced as "502 Upstream error" until the launcher was restarted by hand.
    func restartIfRuntimeConfigChanged(to config: ProxyConfig) {
        let managed = process?.isRunning == true || isGatewayManaged
        // A gateway we did not spawn (left by a crash or a manual start) still
        // serves 18081; converge it to the saved config instead of leaving a
        // process whose endpoint we cannot prove.
        let unmanaged = !managed && isProxyPortInUse()
        guard managed || unmanaged else { return }

        var changes: [String] = []
        let desiredEndpoint = ProxyManager.endpointDescription(for: config)
        if let current = activeEndpoint, current != desiredEndpoint {
            changes.append("endpoint \(current) → \(desiredEndpoint)")
        }
        let desiredRouting = config.mitm?.modelRoutingEnabled ?? false
        if let current = activeModelRouting, current != desiredRouting {
            changes.append("model_routing \(current) → \(desiredRouting)")
        }
        if activeEndpoint == nil {
            changes.append("unmanaged gateway detected")
        }
        guard !changes.isEmpty else { return }

        restartProxy(reason: changes.joined(separator: ", "), completion: nil)
    }

    // MARK: - Launch

    private func findProxyBinary() -> String? {
        // Production: bundled in Resources
        let bundled = Bundle.main.bundlePath + "/Contents/Resources/mitm_proxy"
        if FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        // Development: repo build output（CLI 由 build/Release 运行，据此上溯到仓库根）
        let candidates = [
            Bundle.main.bundlePath + "/../../../../tools/mitm_proxy/mitm_proxy",
            Bundle.main.bundlePath + "/../../../tools/mitm_proxy/mitm_proxy",
            FileSystemPaths.projectRoot.appendingPathComponent("tools/mitm_proxy/mitm_proxy").path
        ]
        for candidate in candidates {
            let resolved = (candidate as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: resolved) {
                return resolved
            }
        }
        return nil
    }

    private func launchProxy() {
        guard process == nil else { return }

        guard let proxyPath = findProxyBinary() else {
            LauncherLogger.warn("Go Proxy binary not found")
            return
        }

        // Fall back to defaults only if the config is unreadable; the gateway
        // itself would then run with its built-in defaults.
        let config = (try? ProxyConfigService().loadForEditor()) ?? .default
        let endpoint = ProxyManager.endpointDescription(for: config)
        let routingEnabled = config.mitm?.modelRoutingEnabled ?? false

        let task = Process()
        task.executableURL = URL(fileURLWithPath: proxyPath)
        task.currentDirectoryURL = URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/Resources")

        // 移除代理环境变量，避免 Go 程序错误地将
        // SOCKS5 代理当作 HTTP CONNECT 代理使用
        // 只传网关真正读取的变量（见 tools/mitm_proxy 里的 os.Getenv 调用）。
        // 之前是把整个 ProcessInfo.environment 传下去，而从 Finder / open / 终端启动
        // 拿到的环境并不相同（XPC_FLAGS、__CFBundleIdentifier、COMMAND_MODE 等），
        // LaunchAgent plist 里写的 EnvironmentVariables 每次都不一样，于是
        // ensureRunning() 判定「plist 变了」→ 每次打开 Launcher 都把常驻网关切掉重启，
        // 正在跑的 SSE 长连接随之断开。
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "PATH", "TMPDIR"] {
            if let value = inherited[key] { env[key] = value }
        }
        if let ca = inherited["GOPROXY_CA_PATH"] { env["GOPROXY_CA_PATH"] = ca }
        if let debug = inherited["MITM_DEBUG"] { env["MITM_DEBUG"] = debug }
        env["MODEL_ROUTING_CONFIG"] = ModelRoutingService().configPath()

        // Pass the upstream proxy configuration and config path from user preferences.
        // UPSTREAM_PROXY carries the type; SOCKS5_PROXY stays for older gateways.
        env["SOCKS5_PROXY"] = "\(config.proxy.host):\(config.proxy.port)"
        env["UPSTREAM_PROXY"] = endpoint
        env["PROXY_CONFIG"] = FileSystemPaths.userProxyConfigFile.path

        task.environment = env

        // 优先交给 launchd：Launcher 退出后网关仍然存活，崩溃由 KeepAlive 自愈。
        // 失败（例如 LaunchAgents 目录不可写）才退回原来的子进程方式。
        let keepAlive = (try? AppSettingsService().load())?.keepGatewayAlive ?? true
        if MitmProxyService().ensureRunning(binary: proxyPath, environment: env, keepAlive: keepAlive) {
            isGatewayManaged = true
            activeEndpoint = endpoint
            activeModelRouting = routingEnabled
            LauncherLogger.info("Go MITM Proxy handed to launchd (upstream: \(endpoint), model_routing: \(routingEnabled), keep_alive: \(keepAlive))")
            verifyProxyHealthViaPort(retries: 8)
            return
        }

        task.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.handleExit(proc) }
        }

        do {
            try task.run()
            self.process = task
            self.activeEndpoint = endpoint
            self.activeModelRouting = routingEnabled
            LauncherLogger.info("Go MITM Proxy started (PID: \(task.processIdentifier), upstream: \(endpoint), model_routing: \(routingEnabled))")
            verifyProxyHealth(retries: 5, expected: task)
        } catch {
            LauncherLogger.error("Failed to start Go MITM Proxy: \(error)")
            self.process = nil
            self.activeEndpoint = nil
            self.activeModelRouting = nil
            scheduleAutoRestart(reason: "launch failed: \(error.localizedDescription)")
        }
    }

    private func handleExit(_ proc: Process) {
        guard process === proc else { return }

        let code = proc.terminationStatus
        let endpoint = activeEndpoint ?? "unknown"
        process = nil
        activeEndpoint = nil
        activeModelRouting = nil
        LauncherLogger.warn("Go MITM Proxy exited (code: \(code), upstream: \(endpoint))")

        guard !isIntentionalStop else { return }
        scheduleAutoRestart(reason: "exit code \(code)")
    }

    // MARK: - Crash backoff

    private func scheduleAutoRestart(reason: String) {
        guard !isIntentionalStop, pendingRestart == nil else { return }

        restartAttempt += 1
        // 2, 4, 8, ... up to 60s: a bind conflict or a missing binary used to
        // retry every 2s forever, spamming the log and burning CPU.
        let delay = min(pow(2.0, Double(restartAttempt)), 60.0)
        LauncherLogger.warn("Go MITM Proxy unavailable (\(reason)); restart #\(restartAttempt) in \(Int(delay))s")

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestart = nil
            self.startProxy()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Port ownership

    /// Releases port 18081 from stray gateways left by an earlier crash or
    /// launcher instance. Only processes whose command line contains
    /// "mitm_proxy" are touched, so an unrelated listener is never killed.
    private func reclaimProxyPort() {
        var strays = listenerPIDs(on: proxyPort)
        guard !strays.isEmpty else { return }

        for pid in strays where isMitmProxy(pid) {
            LauncherLogger.warn("Reclaiming port \(proxyPort) from stray mitm_proxy (PID \(pid))")
            kill(pid, SIGTERM)
        }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            strays = listenerPIDs(on: proxyPort)
            if strays.isEmpty { return }
            usleep(100_000)
        }

        for pid in listenerPIDs(on: proxyPort) where isMitmProxy(pid) {
            kill(pid, SIGKILL)
        }
        usleep(200_000)
    }

    private func listenerPIDs(on port: Int) -> [Int32] {
        guard let result = try? CommandRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]) else {
            return []
        }
        return result.stdout
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .compactMap { Int32($0) }
    }

    private func isMitmProxy(_ pid: Int32) -> Bool {
        guard let result = try? CommandRunner.run("/bin/ps", ["-p", "\(pid)", "-o", "command="]) else {
            return false
        }
        return result.stdout.contains("mitm_proxy")
    }

    private func terminateAndWait(_ p: Process?) {
        guard let p, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Health

    enum GatewayState: Equatable {
        case launchd(pid: Int?)   // 由 LaunchAgent 托管
        case child(pid: Int)      // Launcher 子进程（fallback）
        case stopped

        var isRunning: Bool { self != .stopped }
        var label: String {
            switch self {
            case .launchd(let pid): return pid.map { "launchd 托管 (pid \($0))" } ?? "launchd 托管"
            case .child(let pid):   return "子进程托管 (pid \(pid))"
            case .stopped:          return "未运行"
            }
        }
    }

    /// 后台线程取一份状态快照。`gatewayState` 会同步 spawn `/bin/launchctl`，
    /// 在 SwiftUI body 里直接读等于每次重绘都跑子进程，必须走这个异步入口。
    func gatewayStateAsync(completion: @escaping (GatewayState) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshot = self.gatewayState
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    /// 当前网关的托管方式，供设置页展示与开关使用。
    /// 注意：内部会同步执行 launchctl，不要在 SwiftUI body 里直接调用。
    var gatewayState: GatewayState {
        if isGatewayManaged {
            let svc = MitmProxyService()
            if svc.isRunning() { return .launchd(pid: svc.runningPID()) }
            return .stopped
        }
        if let p = process, p.isRunning { return .child(pid: Int(p.processIdentifier)) }
        return .stopped
    }

    /// 手动重启网关：停掉当前进程并按最新设置重新拉起。
    /// 网关是应用的固定组成部分，用户只需要这一个手动动作。
    func restartGatewayManually() {
        isIntentionalStop = false
        restartProxy(reason: "manual restart by user", completion: nil)
    }

    /// 让网关在不重启进程的前提下重新加载模型路由配置（SIGHUP 热重载）。
    /// 返回 false 表示当前没有可用的网关进程，调用方应退回重启流程。
    func reloadGatewayRouting() -> Bool {
        let pid: pid_t
        if isGatewayManaged {
            guard let running = MitmProxyService().runningPID() else { return false }
            pid = pid_t(running)
        } else if let p = process, p.isRunning {
            pid = p.processIdentifier
        } else {
            return false
        }
        let ok = kill(pid, SIGHUP) == 0
        if ok {
            LauncherLogger.info("Sent SIGHUP to gateway (pid \(pid)) for routing reload")
        } else {
            LauncherLogger.warn("Failed to signal gateway (pid \(pid)) for routing reload")
        }
        return ok
    }

    /// 设置里改了「退出后保留网关」后调用：重写 LaunchAgent 的 RunAtLoad/KeepAlive
    /// 并让网关按新策略重载（launchd 只在 bootstrap 时读 plist）。
    func applyGatewayPolicy() {
        guard isGatewayManaged else { return }
        restartProxy(reason: "gateway keep-alive policy changed", completion: nil)
    }

    func isProxyRunning() -> Bool {
        if isGatewayManaged { return MitmProxyService.isPortListening() }
        return process?.isRunning ?? false
    }

    func healthCheck() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(proxyPort).bigEndian
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

    /// Cheap "is something already listening on the gateway port?" probe.
    private func isProxyPortInUse() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return true }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(proxyPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// launchd 托管时的健康检查：没有 Process 可等，直接探测端口。
    private func verifyProxyHealthViaPort(retries: Int) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var remaining = retries
            while remaining > 0 {
                if MitmProxyService.isPortListening() {
                    DispatchQueue.main.async { self.restartAttempt = 0 }
                    LauncherLogger.info("Go MITM Proxy health check passed (launchd)")
                    return
                }
                usleep(400_000)
                remaining -= 1
            }
            LauncherLogger.error("Go MITM Proxy health check failed after retries (launchd)")
        }
    }

    private func verifyProxyHealth(retries: Int, expected: Process) {
        guard process === expected else { return }

        if healthCheck() {
            restartAttempt = 0
            LauncherLogger.info("Go MITM Proxy health check passed")
            return
        }

        guard retries > 1 else {
            LauncherLogger.error("Go MITM Proxy health check failed after retries")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.verifyProxyHealth(retries: retries - 1, expected: expected)
        }
    }
}
