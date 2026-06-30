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
    private var process: Process?
    private let proxyPort = 18081

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopProxy()
        }
    }

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

    func startProxy() {
        guard process == nil || process?.isRunning == false else { return }
        process = nil

        guard let proxyPath = findProxyBinary() else {
            LauncherLogger.warn("Go Proxy binary not found")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: proxyPath)
        task.currentDirectoryURL = URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/Resources")
        // 移除代理环境变量，避免 Go 程序错误地将
        // SOCKS5 代理当作 HTTP CONNECT 代理使用
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "HTTP_PROXY")
        env.removeValue(forKey: "HTTPS_PROXY")
        env.removeValue(forKey: "http_proxy")
        env.removeValue(forKey: "https_proxy")
        env.removeValue(forKey: "ALL_PROXY")
        env.removeValue(forKey: "all_proxy")
        env["MODEL_ROUTING_CONFIG"] = ModelRoutingService().configPath()
        
        // Pass the SOCKS5 proxy configuration and config path from user preferences
        if let config = try? ProxyConfigService().loadForEditor() {
            env["SOCKS5_PROXY"] = "\(config.proxy.host):\(config.proxy.port)"
        }
        env["PROXY_CONFIG"] = FileSystemPaths.userProxyConfigFile.path
        
        task.environment = env

        task.terminationHandler = { [weak self] proc in
            LauncherLogger.warn("Go MITM Proxy exited (code: \(proc.terminationStatus))")
            self?.process = nil
        }

        do {
            try task.run()
            self.process = task
            LauncherLogger.info("Go MITM Proxy started (PID: \(task.processIdentifier))")

            // Health check: wait for proxy to be ready
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.verifyProxyHealth(retries: 5)
            }
        } catch {
            LauncherLogger.error("Failed to start Go MITM Proxy: \(error)")
            self.process = nil
        }
    }

    func restartProxy() {
        // 1. Kill ALL mitm_proxy processes (not just the one we started)
        let killTask = Process()
        killTask.launchPath = "/usr/bin/pkill"
        killTask.arguments = ["-9", "-f", "mitm_proxy"]
        killTask.launch()
        killTask.waitUntilExit()

        // 2. Wait for port to be free
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !isProxyPortInUse() { break }
            Thread.sleep(forTimeInterval: 0.2)
        }

        // 3. Start fresh
        process = nil
        startProxy()
    }

    func stopProxy() {
        let killTask = Process()
        killTask.launchPath = "/usr/bin/pkill"
        killTask.arguments = ["-9", "-f", "mitm_proxy"]
        killTask.launch()
        killTask.waitUntilExit()
        process = nil
        LauncherLogger.info("Go MITM Proxy stopped")
    }

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

    private func verifyProxyHealth(retries: Int) {
        guard retries > 0 else {
            LauncherLogger.error("Go MITM Proxy health check failed after retries")
            return
        }
        if healthCheck() {
            LauncherLogger.info("Go MITM Proxy health check passed")
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.verifyProxyHealth(retries: retries - 1)
            }
        }
    }
}

