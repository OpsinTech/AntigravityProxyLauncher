import SwiftUI
import AppKit
import Darwin

@main
struct AntigravityProxyLauncherApp: App {
    @StateObject private var appState = LauncherAppState()
    @StateObject private var authViewModel = AuthViewModel()

    init() {
        do {
            try FileSystemPaths.ensureRuntimeDirectoriesExist()
        } catch {
            LauncherLogger.warn("Failed to ensure runtime directories: \(error.localizedDescription)")
        }

        switch LauncherCLICommandParser.parse(from: CommandLine.arguments) {
        case .doctor:
            Darwin.exit(LauncherDoctor().run())
        case .verifyPatched:
            Darwin.exit(LauncherDoctor().verifyPatchedAppFromCLI())
        case .patchAndLaunch:
            Darwin.exit(LauncherDoctor().patchAndLaunchFromCLI())
        case .help:
            print(LauncherCLICommandParser.helpText)
            Darwin.exit(0)
        case .unknown(let arg):
            print("未知参数: \(arg)")
            print(LauncherCLICommandParser.helpText)
            Darwin.exit(2)
        case .none:
            let bundleIdentifier = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if bundleIdentifier.isEmpty {
#if DEBUG
                print("当前进程缺少主 Bundle Identifier，已切换为开发模式继续启动 GUI。")
                LauncherLogger.warn("Missing bundle identifier in DEBUG run. Continue GUI bootstrap for local development.")
#else
                print("当前进程缺少主 Bundle Identifier，已跳过 GUI 启动。")
                print("请使用 .app 方式启动 GUI，或改用 CLI 诊断命令。")
                print(LauncherCLICommandParser.helpText)
                Darwin.exit(2)
#endif
            } else {
                LauncherLogger.info("GUI bootstrap with bundle identifier: \(bundleIdentifier)")
            }

            let hideDock = AntigravityProxyLauncherApp.loadHideDockIconSetting()
            if hideDock {
                NSApplication.shared.setActivationPolicy(.accessory)
                NSApplication.shared.activate(ignoringOtherApps: true)
                LauncherLogger.info("Dock icon hidden (setting from file)")
            } else {
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            break
        }

        LauncherLogger.info("Launcher started in GUI mode. If no terminal output appears, check the app window in Dock/桌面。")
        ProxyManager.shared.startProxy()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(appState)
                .environmentObject(authViewModel)
                .frame(minWidth: 820, minHeight: 560)
                .sheet(isPresented: Binding(
                    get: { !appState.isActivated },
                    set: { _ in }
                )) {
                    ActivationView()
                        .environmentObject(appState)
                        .interactiveDismissDisabled(true)
                }
        }

        MenuBarExtra {
            menuBarContent
                .environmentObject(appState)
                .environmentObject(authViewModel)
        } label: {
            menuBarIcon
        }
    }

    @ViewBuilder
    private var menuBarContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(TargetApp.allCases) { app in
                let status = appState.allAppStatuses[app] ?? MenuBarAppStatus(app: app, isInstalled: false, isRunning: false, isPatched: false)

                if status.isPatched || status.isInstalled || status.isRunning {
                    Menu {
                        if status.isRunning {
                            Button {
                                appState.stopSpecificApp(app)
                            } label: {
                                Label("关闭", systemImage: "stop.circle")
                            }
                        }
                        if status.isPatched && !status.isRunning {
                            Button {
                                appState.launchSpecificApp(app)
                            } label: {
                                Label("启动", systemImage: "play.circle")
                            }
                        }
                        if status.isInstalled {
                            Button {
                                appState.patchSpecificApp(app)
                            } label: {
                                Label("修复", systemImage: "wrench")
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: app.iconName)
                                .frame(width: 18)
                            Text(app.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(status.statusText)
                                .font(.caption)
                                .foregroundStyle(colorForStatus(status))
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: app.iconName)
                            .frame(width: 18)
                            .foregroundStyle(.gray)
                        Text(app.displayName)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(status.statusText)
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                }
            }

            Divider()

            Button("显示主窗口") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                if let window = NSApplication.shared.windows.first(where: { $0.title.contains("Antigravity") }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }

            Divider()

            Button("退出 Launcher") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 240)
    }

    private func colorForStatus(_ status: MenuBarAppStatus) -> Color {
        if status.isRunning { return .green }
        if status.isPatched { return .yellow }
        if status.isInstalled { return .secondary }
        return .gray
    }

    private var menuBarIcon: some View {
        let icon = menuBarResizedIcon()
        return Image(nsImage: icon)
    }

    private func menuBarResizedIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        if let appIcon = NSApp.applicationIconImage,
           let rep = NSBitmapImageRep(
               bitmapDataPlanes: nil,
               pixelsWide: Int(size.width),
               pixelsHigh: Int(size.height),
               bitsPerSample: 8,
               samplesPerPixel: 4,
               hasAlpha: true,
               isPlanar: false,
               colorSpaceName: .deviceRGB,
               bytesPerRow: 0,
               bitsPerPixel: 32
           ) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            appIcon.draw(in: NSRect(origin: .zero, size: size),
                         from: .zero,
                         operation: .copy,
                         fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            let resized = NSImage(size: size)
            resized.addRepresentation(rep)
            return resized
        }
        return NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil) ?? NSImage()
    }

    private static func loadHideDockIconSetting() -> Bool {
        let fileURL = FileSystemPaths.settingsFile
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (json["hideDockIcon"] as? Bool) ?? false
    }
}

class ProxyManager {
    static let shared = ProxyManager()

    private let proxyPort = 18081
    private var process: Process?
    /// True while we deliberately stop the child (restart, app quit) so its
    /// exit handler does not mistake that exit for a crash.
    private var isIntentionalStop = false
    private var isTerminating = false

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
            self?.stopProxy()
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
            // A gateway left behind by an earlier crash/launcher instance keeps
            // 18081 busy; reclaim it instead of failing to bind forever.
            self.reclaimProxyPort()

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

    func stopProxy() {
        isIntentionalStop = true
        pendingRestart?.cancel()
        pendingRestart = nil

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
        let managed = process?.isRunning == true
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
        // Development: build output
        let buildOutput = Bundle.main.bundlePath + "/../../../../tools/mitm_proxy/mitm_proxy"
        let resolved = (buildOutput as NSString).standardizingPath
        if FileManager.default.fileExists(atPath: resolved) {
            return resolved
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
        var env = ProcessInfo.processInfo.environment
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy"] {
            env.removeValue(forKey: key)
        }
        env["MODEL_ROUTING_CONFIG"] = ModelRoutingService().configPath()

        // Pass the upstream proxy configuration and config path from user preferences.
        // UPSTREAM_PROXY carries the type; SOCKS5_PROXY stays for older gateways.
        env["SOCKS5_PROXY"] = "\(config.proxy.host):\(config.proxy.port)"
        env["UPSTREAM_PROXY"] = endpoint
        env["PROXY_CONFIG"] = FileSystemPaths.userProxyConfigFile.path

        task.environment = env

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

    func isProxyRunning() -> Bool {
        process?.isRunning ?? false
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
