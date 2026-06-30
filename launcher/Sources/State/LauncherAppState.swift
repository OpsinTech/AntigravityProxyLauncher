import Foundation
import AppKit

enum LauncherTab: Hashable {
    case overview
    case proxySettings
    case modelRouting
    case diagnostics
    case settings
}

struct MenuBarAppStatus {
    let app: TargetApp
    let isInstalled: Bool
    let isRunning: Bool
    let isPatched: Bool

    var statusText: String {
        if isRunning { return "运行中" }
        if isPatched { return "已就绪" }
        if isInstalled { return "已安装" }
        return "未安装"
    }
}

@MainActor
final class LauncherAppState: ObservableObject {
    @Published var selectedTab: LauncherTab = .overview
    @Published var status: AppStatus = .targetAppMissing
    @Published var appInfo: AppInfo?
    @Published var workflowItems: [LaunchWorkflowItem] = LaunchWorkflowStep.allCases.map {
        LaunchWorkflowItem(id: $0, state: .pending, detail: nil)
    }
    @Published var logLines: [String] = []
    private var allAppLogs: [TargetApp: [String]] = [:]
    @Published var isRunningWorkflow = false
    @Published var proxyConfigDraft: ProxyConfig = .default
    @Published var configStatusMessage: String?
    @Published var configErrorMessage: String?
    @Published var modelRoutingErrorMessage: String?
    @Published var modelRoutingConfigDraft: ModelRoutingConfig = .default
    private var hasLoadedModelRoutingConfig = false
    private let modelRoutingService = ModelRoutingService()
    @Published var settingsDraft: AppSettings = .default
    @Published var settingsStatusMessage: String?
    @Published var settingsErrorMessage: String?
    @Published var launcherVersionText: String = LauncherAppState.resolveLauncherVersion()
    @Published var releaseUpdateInfo: ReleaseUpdateInfo?
    @Published var releaseUpdateStatusMessage: String?
    @Published var releaseUpdateErrorMessage: String?

    @Published var allAppStatuses: [TargetApp: MenuBarAppStatus] = [:]

    @Published var selectedApp: TargetApp = .antigravity {
        didSet {
            guard oldValue != selectedApp else { return }
            UserDefaults.standard.set(selectedApp.rawValue, forKey: "SelectedTargetApp")
            FileSystemPaths.activeApp = selectedApp
            launchService.resetForTargetChange()
            
            // 缓存旧应用的实时日志，并加载新应用的实时日志，实现应用级日志完全隔离
            allAppLogs[oldValue] = logLines
            logLines = allAppLogs[selectedApp] ?? []
            
            appendLog("---------- 切换到 \(selectedApp.displayName) ----------")
            refresh()
        }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "SelectedTargetApp"),
           let app = TargetApp(rawValue: saved) {
            self.selectedApp = app
            FileSystemPaths.activeApp = app
        }

        launchService.onAppTerminated = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.appendLog("修复版应用已退出")
                self.refresh()
            }
        }
    }

    private var hasLoadedProxyConfig = false
    private var lastReleaseCheckAt: Date?

    private let appDetectionService = AppDetectionService()
    private let patchService = PatchService()
    private let verificationService = PatchVerificationService()
    private let launchService = LaunchService()
    private let migrationService = MigrationService()
    private let proxyConfigService = ProxyConfigService()
    private let settingsService = AppSettingsService()
    private let patchedAppHealthService = PatchedAppHealthService()
    private let releaseUpdateService = ReleaseUpdateService()

    func refresh() {
        loadProxyConfig()
        loadModelRoutingConfig()
        loadSettings()
        refreshAllAppStatuses()

        guard let app = appDetectionService.detectInstalledTargetApp() else {
            appInfo = nil
            status = .targetAppMissing
            return
        }

        appInfo = app

        switch patchedAppHealthService.evaluate(targetVersion: app.version) {
            case .missing:
                status = .patchedAppMissing
            case .ready:
                status = launchService.isPatchedAppRunning() ? .running : .patchedReady
            case .outdated:
                status = .patchedAppOutdated
            case .repairRequired(let message):
                status = .repairRequired(message)
        }
    }

    func launchSpecificApp(_ app: TargetApp) {
        selectedApp = app
        refresh()
        launchPatchedAppOnly()
    }

    func patchSpecificApp(_ app: TargetApp) {
        selectedApp = app
        refresh()
        patchOnly()
    }

    func stopSpecificApp(_ app: TargetApp) {
        selectedApp = app
        stopPatchedAppOnly()
        refreshAllAppStatuses()
    }

    func patchOnly() {
        guard !isRunningWorkflow else { return }
        isRunningWorkflow = true

        Task {
            // 修复前校验代理连通性
            let cfg = proxyConfigDraft.proxy
            let probeResult: ProxyProbeResult = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: ProxyConnectivityService().probe(host: cfg.host, port: cfg.port, type: cfg.type))
                }
            }
            if !probeResult.isOK {
                await MainActor.run {
                    appendLog("修复终止: 代理未连接 (\(probeResult.summary))，请先确保代理连通后再修复。")
                    status = .error("代理未连接: \(probeResult.summary)")
                    isRunningWorkflow = false
                }
                return
            }
            await runWorkflow()
        }
    }

    func launchPatchedAppOnly() {
        guard !isRunningWorkflow else { return }
        isRunningWorkflow = true

        let isCLI = selectedApp.targetType == .cliBinary
        appendLog(isCLI ? "验证 CLI 安装..." : "直接启动已修复的应用...")
        status = .launching

        Task {
            do {
                let cliOutput = try await launchService.launchPatchedApp(settings: settingsDraft)
                await MainActor.run {
                    if isCLI {
                        if let output = cliOutput, !output.isEmpty {
                            self.appendLog("agy 版本: \(output)")
                        }
                        self.appendLog("验证通过：Agy CLI 代理注入已就绪，可在终端使用 agy 命令。")
                        self.status = .patchedReady
                    } else {
                        self.appendLog("启动成功！")
                        self.status = .running
                    }
                    self.isRunningWorkflow = false
                }
            } catch {
                await MainActor.run {
                    self.appendLog("\(isCLI ? "验证" : "启动")失败: \(error.localizedDescription)")
                    LauncherLogger.error("Direct launch failed: \(error)")
                    self.status = .error("\(isCLI ? "验证" : "启动")失败: \(error.localizedDescription)")
                    self.isRunningWorkflow = false
                }
            }
        }
    }

    func stopPatchedAppOnly() {
        guard !isRunningWorkflow else { return }

        isRunningWorkflow = true
        appendLog("正在关闭修复版应用...")

        Task {
            try? await runBlocking {
                self.launchService.stopManagedPatchedApp()
            }

            let stillRunning = await MainActor.run {
                self.launchService.isPatchedAppRunning()
            }

            if stillRunning {
                let message = "关闭失败：检测到修复版仍在运行"
                await MainActor.run {
                    self.appendLog(message)
                    self.status = .error(message)
                    self.isRunningWorkflow = false
                }
                return
            }

            await MainActor.run {
                self.appendLog("修复版已关闭")
                self.isRunningWorkflow = false
                self.refresh()
            }
        }
    }

    func clearLogs() {
        logLines.removeAll()
        allAppLogs[selectedApp] = [] // 同步清空当前应用的日志缓存

        let fm = FileManager.default
        var clearedTargets: [String] = []

        do {
            if fm.fileExists(atPath: FileSystemPaths.patchLogFile.path) {
                try fm.removeItem(at: FileSystemPaths.patchLogFile)
                clearedTargets.append("修复日志")
            }


            if clearedTargets.isEmpty {
                appendLog("日志已清理：未发现可删除的日志文件")
            } else {
                appendLog("日志已清理：\(clearedTargets.joined(separator: "、"))")
            }
        } catch {
            appendLog("日志清理失败: \(error.localizedDescription)")
        }
    }

    func cleanEnvironment() {
        guard !isRunningWorkflow else { return }
        
        appendLog("开始清理运行环境（不含日志）...")
        status = .cleaning
        isRunningWorkflow = true
        
        Task {
            do {
                try await runBlocking {
                    let fm = FileManager.default

                    let report: (String) -> Void = { msg in
                        Task { @MainActor in self.appendLog(msg) }
                    }

                    if FileSystemPaths.activeApp.targetType == .cliBinary {
                        // CLI cleanup: remove patched directory and restore original symlink
                        let cliDir = FileSystemPaths.patchedCLIDir
                        if fm.fileExists(atPath: cliDir.path) {
                            try fm.removeItem(at: cliDir)
                            report("已移除 CLI 修复目录: \(cliDir.path)")
                        } else {
                            report("未发现 CLI 修复目录，跳过清理")
                        }

                        // Restore original binary from backup if it exists
                        let targetPath = FileSystemPaths.targetApp
                        let backupPath = targetPath.path + ".original"
                        if fm.fileExists(atPath: backupPath) {
                            if fm.fileExists(atPath: targetPath.path) || (try? targetPath.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                                try fm.removeItem(at: targetPath)
                            }
                            try fm.copyItem(at: URL(fileURLWithPath: backupPath), to: targetPath)
                            report("已还原原始 agy 二进制: \(backupPath)")
                        }
                    } else {
                        if fm.fileExists(atPath: FileSystemPaths.patchedApp.path) {
                            try fm.removeItem(at: FileSystemPaths.patchedApp)
                            report("已移除破解 App: \(FileSystemPaths.patchedApp.path)")
                        } else {
                            report("未发现破解 App，跳过清理")
                        }
                    }

                    let metaURL = FileSystemPaths.appSupportRoot.appendingPathComponent("patch_metadata.json")
                    if fm.fileExists(atPath: metaURL.path) {
                        try fm.removeItem(at: metaURL)
                        report("已移除元数据配置文件: \(metaURL.path)")
                    }
                }
                
                await MainActor.run {
                    self.appendLog("环境清理流程执行完毕！")
                    self.isRunningWorkflow = false
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.appendLog("清理失败: \(error.localizedDescription)")
                    self.status = .error("清理失败: \(error.localizedDescription)")
                    self.isRunningWorkflow = false
                }
            }
        }
    }



    func loadProxyConfig() {
        do {
            proxyConfigDraft = try proxyConfigService.loadForEditor()
            configErrorMessage = nil
            hasLoadedProxyConfig = true
        } catch {
            // 兜底：加载失败时使用默认值，提示用户编辑保存
            proxyConfigDraft = .default
            configErrorMessage = nil
            configStatusMessage = "首次使用，请编辑代理配置后保存"
            appendLog("代理配置初始化完成，使用默认值")
        }
    }

    func loadProxyConfigIfNeeded() {
        if !hasLoadedProxyConfig {
            loadProxyConfig()
        }
    }

    func loadModelRoutingConfig() {
        do {
            modelRoutingConfigDraft = try modelRoutingService.load()
            modelRoutingErrorMessage = nil
            hasLoadedModelRoutingConfig = true
        } catch {
            modelRoutingErrorMessage = "加载模型映射配置失败: \(error.localizedDescription)"
            appendLog("加载模型映射配置失败: \(error.localizedDescription)")
        }
    }

    func loadModelRoutingConfigIfNeeded() {
        if !hasLoadedModelRoutingConfig {
            loadModelRoutingConfig()
        }
    }

    func saveModelRoutingConfig() {
        do {
            try modelRoutingService.save(modelRoutingConfigDraft)
            modelRoutingErrorMessage = nil
            appendLog("模型映射配置已保存。")
        } catch {
            modelRoutingErrorMessage = "保存模型映射配置失败: \(error.localizedDescription)"
            appendLog("保存模型映射配置失败: \(error.localizedDescription)")
        }
    }

    func saveProxyConfig() {
        do {
            let result = try proxyConfigService.saveForNextPatch(proxyConfigDraft)
            configStatusMessage = "配置已保存"
            configErrorMessage = nil
            appendLog("代理配置已保存: \(result.userConfigPath)")
        } catch {
            configErrorMessage = "保存配置失败: \(error.localizedDescription)"
            appendLog("保存代理配置失败: \(error.localizedDescription)")
        }
    }

    func clearConfigStatusMessage() {
        configStatusMessage = nil
    }

    func loadSettings() {
        do {
            var loadedSettings = try settingsService.load()

            if loadedSettings.googleOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loadedSettings.googleOAuthClientID = OAuthConstants.bundledDefaultClientID
            }

            if loadedSettings.googleOAuthClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loadedSettings.googleOAuthClientSecret = OAuthConstants.bundledDefaultClientSecret
            }

            if loadedSettings.releaseFeedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loadedSettings.releaseFeedURL = AppSettings.default.releaseFeedURL
            }

            settingsDraft = loadedSettings
            settingsErrorMessage = nil
            applyDockIconSetting()
            checkLauncherUpdates(manual: false)
        } catch {
            settingsErrorMessage = "加载设置失败: \(error.localizedDescription)"
            appendLog("加载设置失败: \(error.localizedDescription)")
        }
    }

    func saveSettings() {
        do {
            settingsDraft.googleOAuthClientID = settingsDraft.googleOAuthClientID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            settingsDraft.googleOAuthClientSecret = settingsDraft.googleOAuthClientSecret
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try settingsService.save(settingsDraft)
            applyDockIconSetting()
            settingsStatusMessage = "设置已保存"
            settingsErrorMessage = nil
            appendLog("设置已保存: \(FileSystemPaths.settingsFile.path)")
            checkLauncherUpdates(manual: false)
        } catch {
            settingsErrorMessage = "保存设置失败: \(error.localizedDescription)"
            settingsStatusMessage = nil
            appendLog("保存设置失败: \(error.localizedDescription)")
        }
    }

    func checkLauncherUpdates(manual: Bool, forceRefresh: Bool = false) {
        if !forceRefresh, !manual,
           let lastReleaseCheckAt,
           Date().timeIntervalSince(lastReleaseCheckAt) < 600 {
            return
        }

        let feedURL = settingsDraft.releaseFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if feedURL.isEmpty {
            if manual {
                releaseUpdateErrorMessage = "请先填写更新信息 URL"
                releaseUpdateStatusMessage = nil
            }
            return
        }

        let trustedHosts = settingsDraft.releaseFeedTrustedHosts
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        releaseUpdateStatusMessage = "正在检查 Launcher 更新..."
        releaseUpdateErrorMessage = nil
        lastReleaseCheckAt = Date()

        // Detect GitHub repo URL: supports "owner/repo", "github.com/owner/repo", "https://github.com/owner/repo"
        let githubRepo = parseGitHubRepo(from: feedURL)

        Task {
            do {
                let result: ReleaseUpdateInfo
                if let (owner, repo) = githubRepo {
                    result = try await releaseUpdateService.checkGitHubRepo(
                        owner: owner, repo: repo, currentVersion: launcherVersionText,
                        githubToken: settingsDraft.githubToken,
                        forceRefresh: forceRefresh
                    )
                } else {
                    result = try await releaseUpdateService.check(
                        currentVersion: launcherVersionText,
                        urlString: feedURL,
                        trustedHostPatterns: trustedHosts
                    )
                }
                releaseUpdateInfo = result

                if result.isUpdateAvailable {
                    if isReleaseVersionIgnored(result.latestVersion) {
                        releaseUpdateStatusMessage = "已忽略版本 \(result.latestVersion) 的提醒"
                    } else {
                        releaseUpdateStatusMessage = "发现新版本 \(result.latestVersion)"
                    }
                    appendLog("发现 Launcher 新版本: \(result.latestVersion)")
                } else {
                    releaseUpdateStatusMessage = "当前已是最新版本 (\(result.currentVersion))"
                    appendLog("Launcher 版本检查完成：已是最新版本")
                }
                releaseUpdateErrorMessage = nil
            } catch {
                if manual {
                    releaseUpdateErrorMessage = "更新检查失败: \(error.localizedDescription)"
                }
                releaseUpdateStatusMessage = nil
                appendLog("更新检查失败: \(error.localizedDescription)")
            }
        }
    }

    func isReleaseVersionIgnored(_ version: String) -> Bool {
        let ignored = settingsDraft.releaseIgnoredVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ignored.isEmpty else {
            return false
        }
        return ignored == version
    }

    func ignoreCurrentReleaseUpdate() {
        guard let latest = releaseUpdateInfo?.latestVersion, !latest.isEmpty else {
            return
        }

        settingsDraft.releaseIgnoredVersion = latest

        do {
            try settingsService.save(settingsDraft)
            settingsStatusMessage = "已忽略版本 \(latest) 的更新提醒"
            settingsErrorMessage = nil
            releaseUpdateStatusMessage = "已忽略版本 \(latest) 的提醒"
            releaseUpdateErrorMessage = nil
            appendLog("已忽略 Launcher 更新版本: \(latest)")
        } catch {
            settingsErrorMessage = "保存忽略版本失败: \(error.localizedDescription)"
            appendLog("保存忽略版本失败: \(error.localizedDescription)")
        }
    }

    func clearIgnoredReleaseVersion() {
        let previous = settingsDraft.releaseIgnoredVersion
        guard !previous.isEmpty else {
            return
        }

        settingsDraft.releaseIgnoredVersion = ""

        do {
            try settingsService.save(settingsDraft)
            settingsStatusMessage = "已恢复更新提醒"
            settingsErrorMessage = nil
            releaseUpdateStatusMessage = "已恢复更新提醒"
            releaseUpdateErrorMessage = nil
            appendLog("已恢复 Launcher 更新提醒")
        } catch {
            settingsDraft.releaseIgnoredVersion = previous
            settingsErrorMessage = "恢复更新提醒失败: \(error.localizedDescription)"
            appendLog("恢复更新提醒失败: \(error.localizedDescription)")
        }
    }


    func applyDockIconSetting() {
        if settingsDraft.hideDockIcon {
            NSApplication.shared.setActivationPolicy(.accessory)
        } else {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func refreshAllAppStatuses() {
        var statuses: [TargetApp: MenuBarAppStatus] = [:]
        for app in TargetApp.allCases {
            let previous = FileSystemPaths.activeApp
            FileSystemPaths.activeApp = app
            defer { FileSystemPaths.activeApp = previous }

            let isInstalled = appDetectionService.detectInstalledTargetApp() != nil
            let patchedExists: Bool = {
                if app.targetType == .cliBinary {
                    return FileManager.default.fileExists(atPath: FileSystemPaths.patchedCLIWrapper.path)
                }
                return FileManager.default.fileExists(atPath: FileSystemPaths.patchedApp.path)
            }()
            let isRunning = launchService.isPatchedAppRunning()

            statuses[app] = MenuBarAppStatus(
                app: app,
                isInstalled: isInstalled,
                isRunning: isRunning,
                isPatched: patchedExists
            )
        }
        allAppStatuses = statuses
    }

    private func runWorkflow() async {
        isRunningWorkflow = true
        resetWorkflow()
        status = .patching
        appendLog("开始执行修复流程")

        do {
            markStep(.detect, as: .running)
            guard let app = appDetectionService.detectInstalledTargetApp() else {
                markStep(.detect, as: .failed, detail: "未找到 \(selectedApp.defaultPath)")
                status = .targetAppMissing
                appendLog("失败: 未检测到原版应用 (\(selectedApp.displayName))")
                isRunningWorkflow = false
                return
            }
            appInfo = app
            markStep(.detect, as: .completed, detail: "\(app.version)")
            appendLog("检测到应用版本: \(app.version)")

            markStep(.migration, as: .running)
            try await runBlocking {
                try self.migrationService.migrateSandboxData()
            }
            markStep(.migration, as: .completed)
            appendLog("数据迁移完成")

            markStep(.patch, as: .running)
            try await runBlocking {
                try self.patchService.preparePatchedBundle(onProgress: { message in
                    Task { @MainActor in
                        self.appendLog(message)
                    }
                })
            }
            markStep(.patch, as: .completed)
            appendLog("修复包处理完成")

            markStep(.verify, as: .running)
            try await runBlocking {
                try self.verificationService.verifyPatchedResult()
            }
            markStep(.verify, as: .completed)
            appendLog("修复结果验证通过")

            markStep(.launch, as: .completed, detail: "待手动启动")
            status = .patchedReady
            appendLog("修复完成，可手动启动修复版")
        } catch {
            markCurrentRunningStepFailed(with: error.localizedDescription)
            status = .error("修复失败: \(error.localizedDescription)")
            appendLog("失败: \(error.localizedDescription)")

        }

        isRunningWorkflow = false
    }

    private func runBlocking<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func resetWorkflow() {
        workflowItems = LaunchWorkflowStep.allCases.map {
            LaunchWorkflowItem(id: $0, state: .pending, detail: nil)
        }
    }

    private func markStep(_ step: LaunchWorkflowStep, as state: LaunchWorkflowStepState, detail: String? = nil) {
        guard let index = workflowItems.firstIndex(where: { $0.id == step }) else { return }
        workflowItems[index].state = state
        workflowItems[index].detail = detail
    }

    private func markCurrentRunningStepFailed(with detail: String) {
        guard let index = workflowItems.firstIndex(where: { $0.state == .running }) else { return }
        workflowItems[index].state = .failed
        workflowItems[index].detail = detail
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        logLines.append("[\(timestamp)] \(message)")
        if logLines.count > 1000 {
            logLines.removeFirst(logLines.count - 1000)
        }
        allAppLogs[selectedApp] = logLines // 同步将日志缓存更新到当前应用
    }

    /// Parse a GitHub repo URL into (owner, repo). Supports formats:
    /// - "owner/repo"
    /// - "github.com/owner/repo"
    /// - "https://github.com/owner/repo"
    private func parseGitHubRepo(from urlString: String) -> (String, String)? {
        var cleaned = urlString.trimmingCharacters(in: .whitespaces)
        // Strip protocol
        if let range = cleaned.range(of: "https://") {
            cleaned = String(cleaned[range.upperBound...])
        } else if let range = cleaned.range(of: "http://") {
            cleaned = String(cleaned[range.upperBound...])
        }
        // Strip host if present
        if cleaned.hasPrefix("github.com/") {
            cleaned = String(cleaned.dropFirst("github.com/".count))
        }
        // Strip trailing slash
        if cleaned.hasSuffix("/") {
            cleaned = String(cleaned.dropLast())
        }
        let parts = cleaned.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private static func resolveLauncherVersion() -> String {
        // Try bundled version.txt first (release builds)
        if let url = Bundle.main.url(forResource: "version", withExtension: "txt"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            let version = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !version.isEmpty { return version }
        }

        // Try Resources/version.txt relative to launcher root (DEBUG / dev builds)
        let resourcesVersionURL = FileSystemPaths.launcherRoot
            .appendingPathComponent("Resources/version.txt")
        if let content = try? String(contentsOf: resourcesVersionURL, encoding: .utf8) {
            let version = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !version.isEmpty { return version }
        }

        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty { return version }

        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !build.isEmpty { return build }

        return "0.1.0-dev"
    }
}
