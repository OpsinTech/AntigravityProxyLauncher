import Foundation
import AppKit
import Darwin
import OSLog

private let log = Logger(subsystem: "com.antigravity.proxylauncher", category: "Launch")

enum LaunchError: LocalizedError {
    case cliSmokeTestFailed(String)
    case appBundleLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliSmokeTestFailed(let output):
            return "CLI 验证失败: \(output)"
        case .appBundleLaunchFailed(let reason):
            return reason
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

        // P1: proactively ensure a valid combined CA bundle at Launcher startup (silent), so the
        // target app gets a correct bundle on first launch instead of hitting a stale/partial one.
        Task.detached(priority: .utility) { [weak self] in
            self?.ensureCombinedCABundle(env: nil)
        }
    }

    func launchPatchedApp(settings: AppSettings? = nil) async throws -> String? {
        // CLI targets: run a smoke test, return version output
        if FileSystemPaths.activeApp.targetType == .cliBinary {
            return try await launchCLISmokeTest(settings: settings)
        }

        // 停止已有实例必须在后台线程，避免阻塞主线程（内部有轮询等待）
        stopManagedPatchedApp()

        // Pre-launch diagnostics: check critical files exist
        let patchedAppURL = FileSystemPaths.patchedApp
        guard FileManager.default.fileExists(atPath: patchedAppURL.path) else {
            throw LaunchError.appBundleLaunchFailed("修复版 App 不存在: \(patchedAppURL.path)，请先执行修复")
        }

        let resourcesDir = patchedAppURL.appendingPathComponent("Contents/Resources")
        let dylibPath = resourcesDir.appendingPathComponent("libAntigravityTun.dylib").path
        guard FileManager.default.fileExists(atPath: dylibPath) else {
            throw LaunchError.appBundleLaunchFailed("dylib 缺失: \(dylibPath)，请重新修复")
        }

        let executablePath = patchedAppURL
            .appendingPathComponent("Contents/MacOS/\(FileSystemPaths.activeApp.executableName)").path
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw LaunchError.appBundleLaunchFailed("可执行文件不可用: \(executablePath)，请重新修复")
        }

        try? clearQuarantineAttributes()

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
        // SSL_CERT_FILE replaces the entire trust store for Go, so we must create a combined
        // bundle that includes both system root CAs AND the goproxy CA. Using goproxy CA alone
        // breaks TLS verification for all non-MITM traffic (e.g., OAuth to oauth2.googleapis.com).
        let caCertPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/antigravity/goproxy_ca.pem").path
        let combinedCAPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/antigravity/combined_ca.pem").path
        env["NODE_EXTRA_CA_CERTS"] = caCertPath

        // Ensure a valid combined CA bundle exists (system roots + goproxy CA) and inject it via
        // SSL_CERT_FILE. SSL_CERT_FILE REPLACES Go's entire trust store (it is not additive): if it
        // points at the goproxy CA alone, every real HTTPS endpoint (e.g. oauth2.googleapis.com)
        // fails with "x509: certificate signed by unknown authority". So we must always build a
        // bundle of SYSTEM roots + goproxy CA; if the system roots cannot be obtained we leave
        // SSL_CERT_FILE unset so Go falls back to the OS trust store (strictly safer than a
        // goproxy-only bundle). Detailed steps are logged for diagnostics.
        ensureCombinedCABundle(env: &env)

        config.environment = env
        config.createsNewApplicationInstance = true
        config.promptsUserIfNeeded = false

        do {
            let app = try await NSWorkspace.shared.openApplication(
                at: patchedAppURL,
                configuration: config
            )
            self.activeAppPID = app.processIdentifier
            return nil
        } catch {
            throw LaunchError.appBundleLaunchFailed("启动失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Combined CA bundle management

    /// Validate a combined CA bundle: must exist and contain at least 2 certificates
    /// (the system roots plus the goproxy CA). A stale/partial bundle that only contains
    /// the goproxy CA must never be trusted.
    private func combinedBundleIsValid(_ path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        let count = content.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1
        return count >= 2
    }

    /// Ensure a valid combined CA bundle (system root CAs + goproxy CA) exists.
    ///
    /// When `env` is non-nil, injects `SSL_CERT_FILE` into it (launch path). When nil, the
    /// method only ensures/regenerates the bundle on disk (silent startup pre-check).
    ///
    /// SSL_CERT_FILE REPLACES Go's entire trust store (not additive). If we cannot obtain the
    /// system root CAs we MUST NOT set SSL_CERT_FILE at all — leaving it unset lets Go fall back
    /// to the OS trust store, which is strictly safer than pointing it at a goproxy-only bundle
    /// (which breaks every real HTTPS, e.g. oauth2.googleapis.com → "x509: unknown authority").
    ///
    /// Every resolution step is logged so field issues can be diagnosed from the Launcher log
    /// (which source supplied the roots, how many certs, and whether the bundle is valid).
    private func ensureCombinedCABundle(env: inout [String: String]?) {
        let caCertPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/antigravity/goproxy_ca.pem").path
        let combinedCAPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/antigravity/combined_ca.pem").path

        // Only regenerate when the bundle is missing or invalid. We never reuse a partial bundle
        // just because its mtime is newer than the goproxy CA.
        let needRegen = !FileManager.default.fileExists(atPath: combinedCAPath)
            || !combinedBundleIsValid(combinedCAPath)
        if needRegen {
            log.info("[Launch] Combined CA bundle missing or invalid; (re)generating (path=\(combinedCAPath))")
        }

        if needRegen, let goproxyCA = try? String(contentsOfFile: caCertPath, encoding: .utf8) {
            // Collect system root CAs from as many sources as possible, in priority order:
            //   1. /etc/ssl/cert.pem            (Homebrew / Xcode CLT; absent on clean Macs)
            //   2. System keychain roots        (every macOS, clean or otherwise)
            //   3. Login keychain roots         (user-installed / enterprise roots)
            var systemRoots = ""
            var source = "none"

            if let systemCA = try? String(contentsOfFile: "/etc/ssl/cert.pem", encoding: .utf8),
               !systemCA.isEmpty {
                systemRoots = systemCA
                source = "/etc/ssl/cert.pem"
            } else {
                log.info("[Launch] /etc/ssl/cert.pem unavailable (no Xcode CLT/Homebrew); falling back to keychain")
                // Run security directly (not via CommandRunner, which throws on non-zero exit) so a
                // non-zero status does not silently abort root extraction.
                systemRoots = runSecurityFindCerts(keychain: "/System/Library/Keychains/SystemRootCertificates.keychain")
                if !systemRoots.isEmpty {
                    source = "SystemRootCertificates.keychain"
                }
            }

            // Supplement (or fall back to) the login keychain for user/enterprise-installed roots.
            if systemRoots.isEmpty {
                let loginRoots = runSecurityFindCerts(keychain: "\(NSHomeDirectory())/Library/Keychains/login.keychain-db")
                if !loginRoots.isEmpty {
                    systemRoots = loginRoots
                    source = "login.keychain-db"
                }
            } else {
                let loginRoots = runSecurityFindCerts(keychain: "\(NSHomeDirectory())/Library/Keychains/login.keychain-db")
                if !loginRoots.isEmpty {
                    systemRoots += "\n" + loginRoots
                    source += " + login.keychain-db"
                }
            }

            let rootCount = systemRoots.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1
            log.info("[Launch] System root CAs obtained: source=\(source) count=\(rootCount)")

            if !systemRoots.isEmpty {
                let combined = systemRoots + "\n" + goproxyCA
                do {
                    try combined.write(toFile: combinedCAPath, atomically: true, encoding: .utf8)
                    log.info("[Launch] Combined CA bundle written (path=\(combinedCAPath))")
                } catch {
                    log.error("[Launch] Failed to write combined CA bundle: \(error.localizedDescription)")
                }
            } else {
                // No system roots obtainable — do NOT write a goproxy-only bundle. See note above.
                log.error("[Launch] Could not obtain system root CAs from any source; SSL_CERT_FILE left unset so Go uses the OS trust store")
            }
        }

        // Inject SSL_CERT_FILE only when we have a VALID combined bundle. Otherwise leave it unset
        // so Go verifies against the system store.
        if combinedBundleIsValid(combinedCAPath) {
            env?["SSL_CERT_FILE"] = combinedCAPath
            log.info("[Launch] SSL_CERT_FILE set -> \(combinedCAPath)")
        } else {
            log.warning("[Launch] No valid combined CA bundle; SSL_CERT_FILE left unset (Go uses OS trust store)")
        }
    }

    /// Run `security find-certificate -a -p <keychain>` and return its PEM output.
    /// Uses Process directly so a non-zero exit does not throw (unlike CommandRunner).
    private func runSecurityFindCerts(keychain: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-certificate", "-a", "-p", keychain]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("[Launch] security find-certificate failed for \(keychain): \(error.localizedDescription)")
            return ""
        }
        if process.terminationStatus != 0 {
            let msg = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            log.error("[Launch] security find-certificate exited \(process.terminationStatus) for \(keychain)\(msg.isEmpty ? "" : ": \(msg)")")
            return ""
        }
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
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
        let activeApp = FileSystemPaths.activeApp
        let processNames = [activeApp.cliRealBinaryName, activeApp.executableName]
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
            let result = try CommandRunner.run("/usr/bin/pgrep", ["-f", FileSystemPaths.activeApp.cliRealBinaryName])
            return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }
}
