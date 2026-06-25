import Foundation
import AppKit
import Darwin

enum LaunchError: LocalizedError {
    case cliSmokeTestFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliSmokeTestFailed(let output):
            return "CLI 验证失败: \(output)"
        }
    }
}

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

    func launchPatchedApp(settings: AppSettings? = nil) async throws -> String? {
        // CLI targets: run a smoke test, return version output
        if FileSystemPaths.activeApp.targetType == .cliBinary {
            return try await launchCLISmokeTest(settings: settings)
        }

        // 停止已有实例必须在后台线程，避免阻塞主线程（内部有轮询等待）
        stopManagedPatchedApp()

        try? clearQuarantineAttributes()

        let resourcesDir = FileSystemPaths.patchedApp
            .appendingPathComponent("Contents/Resources")
        let dylibPath = resourcesDir.appendingPathComponent("libAntigravityTun.dylib").path

        let config = NSWorkspace.OpenConfiguration()
        let activeApp = FileSystemPaths.activeApp
        config.arguments = activeApp.launchArguments

        var env = ProcessInfo.processInfo.environment
        // 移除代理环境变量，避免 Go 程序（language_server）
        // 错误地将系统代理当作 HTTP CONNECT 代理使用
        env.removeValue(forKey: "HTTP_PROXY")
        env.removeValue(forKey: "HTTPS_PROXY")
        env.removeValue(forKey: "http_proxy")
        env.removeValue(forKey: "https_proxy")
        env.removeValue(forKey: "ALL_PROXY")
        env.removeValue(forKey: "all_proxy")

        for (key, value) in activeApp.environmentVariables {
            env[key] = value
        }

        env["DYLD_INSERT_LIBRARIES"] = dylibPath
        env["ANTIGRAVITY_CONFIG"] = FileSystemPaths.userProxyConfigFile.path
        // Dylib 日志：始终开启文件写入，级别由代理配置控制
        env["ANTIGRAVITY_LOG_FILE"] = "1"
        let proxyCfg = (try? ProxyConfigService().loadForEditor()) ?? .default
        env["ANTIGRAVITY_LOG_LEVEL"] = proxyCfg.logLevel
        // Trust MITM proxy's CA cert for Go binaries (SSL_CERT_FILE) and Node.js (NODE_EXTRA_CA_CERTS)
        let caCertPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/antigravity/goproxy_ca.pem").path
        env["SSL_CERT_FILE"] = caCertPath
        env["NODE_EXTRA_CA_CERTS"] = caCertPath

        config.environment = env
        config.createsNewApplicationInstance = true
        config.promptsUserIfNeeded = false

        let app = try await NSWorkspace.shared.openApplication(
            at: FileSystemPaths.patchedApp,
            configuration: config
        )
        self.activeAppPID = app.processIdentifier
        return nil
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
        if FileSystemPaths.activeApp.targetType == .cliBinary {
            stopCLIProcesses()
            return
        }

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
        if FileSystemPaths.activeApp.targetType == .cliBinary {
            return isCLIProcessRunning()
        }
        return !allRunningPatchedProcesses().isEmpty
    }

    /// 当用户切换目标 app 时，清除上一个 app 的运行状态
    func resetForTargetChange() {
        activeAppPID = nil
    }

    func runtimeEnvironmentDescription() -> [String: String] {
        return [
            "DYLD_INSERT_LIBRARIES": FileSystemPaths.patchedApp
                .appendingPathComponent("Contents/Resources/libAntigravityTun.dylib").path,
            "ANTIGRAVITY_CONFIG": FileSystemPaths.userProxyConfigFile.path
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

    // MARK: - CLI process management

    private func launchCLISmokeTest(settings: AppSettings? = nil) async throws -> String {
        stopCLIProcesses()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = FileSystemPaths.patchedCLIWrapper
                process.arguments = FileSystemPaths.activeApp.cliVersionArgs

                var env = ProcessInfo.processInfo.environment
                env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
                env.removeValue(forKey: "ANTIGRAVITY_CONFIG")
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(throwing: LaunchError.cliSmokeTestFailed(output))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func stopCLIProcesses() {
        let processNames = ["agy-real", "agy"]
        for name in processNames {
            do {
                let result = try CommandRunner.run("/usr/bin/pgrep", ["-f", name])
                let pids = result.stdout
                    .split(separator: "\n")
                    .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
                for pid in pids {
                    if pid == getpid() { continue }
                    kill(pid, SIGTERM)
                }
            } catch {
                // pgrep returns non-zero when no matches — expected
            }
        }
        // Brief wait then force kill
        Thread.sleep(forTimeInterval: 0.5)
        for name in processNames {
            do {
                let result = try CommandRunner.run("/usr/bin/pgrep", ["-f", name])
                let pids = result.stdout
                    .split(separator: "\n")
                    .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
                for pid in pids {
                    if pid == getpid() { continue }
                    kill(pid, SIGKILL)
                }
            } catch { }
        }
        activeAppPID = nil
    }

    private func isCLIProcessRunning() -> Bool {
        do {
            let result = try CommandRunner.run("/usr/bin/pgrep", ["-f", "agy-real"])
            return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }
}
