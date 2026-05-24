import Foundation
import AppKit
import Darwin

final class LaunchService {
    private var activeAppPID: pid_t?
    var onAppTerminated: (() -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopManagedPatchedApp()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let pid = self.activeAppPID,
                  let terminatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  terminatedApp.processIdentifier == pid else { return }
            self.activeAppPID = nil
            self.onAppTerminated?()
        }
    }

    func launchPatchedApp(settings: AppSettings? = nil) async throws {
        // 停止已有实例必须在后台线程，避免阻塞主线程（内部有轮询等待）
        stopManagedPatchedApp()

        try? clearQuarantineAttributes()

        let resourcesDir = FileSystemPaths.patchedApp
            .appendingPathComponent("Contents/Resources")
        let dylibPath = resourcesDir.appendingPathComponent("libAntigravityTun.dylib").path
        let configPath = resourcesDir.appendingPathComponent("proxy_config.json").path

        let config = NSWorkspace.OpenConfiguration()
        let activeApp = FileSystemPaths.activeApp
        config.arguments = activeApp.launchArguments

        var env = ProcessInfo.processInfo.environment
        for (key, value) in activeApp.environmentVariables {
            env[key] = value
        }

        env["DYLD_INSERT_LIBRARIES"] = dylibPath
        env["ANTIGRAVITY_CONFIG"] = configPath

        if settings?.enableRuntimeLog == true {
            try FileManager.default.createDirectory(
                at: FileSystemPaths.runtimeLogsRoot,
                withIntermediateDirectories: true
            )
            env["ANTIGRAVITY_LOG_FILE"] = "1"
            env["ANTIGRAVITY_LOG_LEVEL"] = settings?.runtimeLogLevel ?? "Info"
            env["ANTIGRAVITY_LOG_PATH"] = FileSystemPaths.runtimeLogFile.path
        } else {
            env.removeValue(forKey: "ANTIGRAVITY_LOG_FILE")
            env.removeValue(forKey: "ANTIGRAVITY_LOG_LEVEL")
            env.removeValue(forKey: "ANTIGRAVITY_LOG_PATH")
        }

        config.environment = env
        config.createsNewApplicationInstance = true
        config.promptsUserIfNeeded = false

        let app = try await NSWorkspace.shared.openApplication(
            at: FileSystemPaths.patchedApp,
            configuration: config
        )
        self.activeAppPID = app.processIdentifier
    }

    /// 清理应用的隔离属性，避免每次启动都需要输入密码
    private func clearQuarantineAttributes() throws {
        let appPath = FileSystemPaths.patchedApp.path

        _ = try? CommandRunner.run("/usr/bin/xattr", ["-d", "com.apple.quarantine", appPath])
        _ = try? CommandRunner.run("/usr/bin/xattr", ["-cr", appPath])

        let activeApp = FileSystemPaths.activeApp
        if activeApp == .gemini || activeApp == .antigravityIDE {
            let executablePath = FileSystemPaths.patchedApp
                .appendingPathComponent("Contents/MacOS/\(activeApp.executableName)").path
            _ = try? CommandRunner.run("/usr/bin/xattr", ["-cr", executablePath])
            _ = try? CommandRunner.run("/bin/chmod", ["+x", executablePath])
        }
    }

    func launchOriginalApp() async throws {
        let config = NSWorkspace.OpenConfiguration()
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        env.removeValue(forKey: "ANTIGRAVITY_CONFIG")
        config.environment = env
        config.createsNewApplicationInstance = true
        config.promptsUserIfNeeded = false

        let app = try await NSWorkspace.shared.openApplication(
            at: FileSystemPaths.targetApp,
            configuration: config
        )
        self.activeAppPID = app.processIdentifier
    }

    func stopManagedPatchedApp() {
        let allRunning = allRunningPatchedProcesses()
        guard !allRunning.isEmpty else {
            activeAppPID = nil
            return
        }

        // 1. 优雅退出主程序
        if let bundleID = patchedBundleIdentifier() {
            requestGracefulQuit(bundleIdentifier: bundleID)
        }

        // 2. terminate 主程序
        for app in allRunning {
            _ = app.terminate()
        }

        // 3. 等待 1.5 秒让进程自然退出
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if allRunningPatchedProcesses().isEmpty {
                activeAppPID = nil
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        // 4. 强制终止主程序及其进程组
        let remaining = allRunningPatchedProcesses()
        for app in remaining {
            let pid = app.processIdentifier
            // 杀掉整个进程组（Electron helpers 通常在同一个进程组）
            kill(-pid, SIGTERM)
        }

        // 5. 再等 0.5 秒
        var retry = allRunningPatchedProcesses()
        let forceDeadline = Date().addingTimeInterval(0.5)
        while Date() < forceDeadline {
            retry = allRunningPatchedProcesses()
            if retry.isEmpty {
                activeAppPID = nil
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        // 6. 最后手段：SIGKILL 整个进程组 + helper bundle 清理
        for app in retry {
            kill(-app.processIdentifier, SIGKILL)
            _ = app.forceTerminate()
        }

        // 7. 清理所有 helper bundle ID 的残留进程
        terminateHelperProcesses()

        activeAppPID = nil
    }

    func isPatchedAppRunning() -> Bool {
        !allRunningPatchedProcesses().isEmpty
    }

    /// 当用户切换目标 app 时，清除上一个 app 的运行状态
    func resetForTargetChange() {
        activeAppPID = nil
    }

    func runtimeEnvironmentDescription() -> [String: String] {
        let dylibPath = FileSystemPaths.patchedApp
            .appendingPathComponent("Contents/Resources/libAntigravityTun.dylib")
            .path
        let configPath = FileSystemPaths.patchedApp
            .appendingPathComponent("Contents/Resources/proxy_config.json")
            .path

        return [
            "DYLD_INSERT_LIBRARIES": dylibPath,
            "ANTIGRAVITY_CONFIG": configPath
        ]
    }

    /// 查找所有与 patched app 相关的运行进程（主程序 + helpers）
    private func allRunningPatchedProcesses() -> [NSRunningApplication] {
        let patchedPath = FileSystemPaths.patchedApp.standardizedFileURL.path

        var results: [NSRunningApplication] = []

        // 通过 bundle ID 查找主程序
        if let bundleID = patchedBundleIdentifier() {
            let matching = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            for app in matching {
                if let bundlePath = app.bundleURL?.standardizedFileURL.path {
                    if bundlePath == patchedPath {
                        results.append(app)
                    }
                }
            }
        }

        // 通过 activeAppPID 兜底（仅当 PID 对应的进程 bundle path 匹配当前 patched app）
        if results.isEmpty, let pid = activeAppPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            if let bundlePath = app.bundleURL?.standardizedFileURL.path,
               bundlePath == patchedPath {
                results.append(app)
            }
        }

        // 查找 patched app 内部的 helper 进程（bundleURL 以 patchedPath 为前缀）
        for helperBundleID in FileSystemPaths.activeApp.helperBundleIdentifiers {
            let helpers = NSRunningApplication.runningApplications(withBundleIdentifier: helperBundleID)
            for helper in helpers {
                if let bundlePath = helper.bundleURL?.standardizedFileURL.path,
                   bundlePath.hasPrefix(patchedPath + "/") {
                    results.append(helper)
                }
            }
        }

        return results
    }

    /// 终止所有 helper bundle ID 对应的残留进程
    private func terminateHelperProcesses() {
        for helperBundleID in FileSystemPaths.activeApp.helperBundleIdentifiers {
            let helpers = NSRunningApplication.runningApplications(withBundleIdentifier: helperBundleID)
            for helper in helpers {
                _ = helper.forceTerminate()
            }
        }
    }

    private func patchedBundleIdentifier() -> String? {
        let infoURL = FileSystemPaths.patchedApp.appendingPathComponent("Contents/Info.plist")
        let dict = NSDictionary(contentsOf: infoURL) as? [String: Any]
        return dict?["CFBundleIdentifier"] as? String
    }

    private func requestGracefulQuit(bundleIdentifier: String) {
        let script = "tell application id \"\(bundleIdentifier)\" to quit"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        process.waitUntilExit()
    }
}
