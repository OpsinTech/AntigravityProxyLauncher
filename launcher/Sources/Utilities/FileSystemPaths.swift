import Foundation

enum FileSystemPaths {
    private static var sourceFileURL: URL {
        // Release 下原先用 Bundle.main.bundleURL 拼路径：对 CLI 可执行文件来说
        // bundleURL 就是它所在的目录（如 launcher/build/Release），于是 launcherRoot
        // 也被算成那里，所有资源候选路径全部错位（bundledDylib 变成
        // launcher/build/Release/Resources/...，永远不存在）。
        // #filePath 是编译期常量，本地构建机一定存在，优先用它；
        // 拷到别的机器后它会失效，再退回 bundleURL 的老逻辑。
        let compiled = URL(fileURLWithPath: #filePath)
        if FileManager.default.fileExists(atPath: compiled.path) {
            return compiled
        }
        return Bundle.main.bundleURL.appendingPathComponent("Sources/Utilities/FileSystemPaths.swift")
    }

    private static var appBundleResourceRoot: URL? {
        // 只有真正的 .app 才用 Bundle.main.resourceURL。CLI 可执行文件的
        // resourceURL 就是它所在的目录（如 build/Release），资源查找会全部落空，
        // 于是 bundledDylib 之类的路径变成不存在的假路径。
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.resourceURL
    }

    private static func bundleResourceURL(
        named name: String,
        withExtension ext: String,
        subdirectory: String? = nil
    ) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
            return url
        }

#if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
            return url
        }
#endif

        guard let root = appBundleResourceRoot else {
            return nil
        }

        if let subdirectory, !subdirectory.isEmpty {
            return root
                .appendingPathComponent(subdirectory, isDirectory: true)
                .appendingPathComponent("\(name).\(ext)")
        }

        return root.appendingPathComponent("\(name).\(ext)")
    }

    static var launcherRoot: URL {
        sourceFileURL
            .deletingLastPathComponent() // Utilities
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // launcher
    }

    static var projectRoot: URL {
        launcherRoot.deletingLastPathComponent()
    }

    static var siblingProxyRepoRoot: URL {
        projectRoot
            .deletingLastPathComponent()
            .appendingPathComponent("antigravity_macos_proxy", isDirectory: true)
    }

    private static let _activeAppLock = NSLock()
    private static var _activeApp: TargetApp = .antigravity
    static var activeApp: TargetApp {
        get {
            _activeAppLock.lock()
            defer { _activeAppLock.unlock() }
            return _activeApp
        }
        set {
            _activeAppLock.lock()
            _activeApp = newValue
            _activeAppLock.unlock()
        }
    }

    static var targetApp: URL {
        let path = activeApp.defaultPath
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    static var patchedApp: URL {
        if activeApp.targetType == .cliBinary {
            return patchedCLIWrapper
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/\(activeApp.patchedName)", isDirectory: true)
    }

    static var appSupportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AntigravityProxy/\(activeApp.id)", isDirectory: true)
    }

    static var settingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/antigravity/settings.json")
    }

    static var metadataRoot: URL {
        appSupportRoot.appendingPathComponent("metadata", isDirectory: true)
    }

    static var userConfigRoot: URL {
        switch activeApp {
        case .antigravity:
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Antigravity", isDirectory: true)
        case .antigravityIDE:
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Antigravity IDE", isDirectory: true)
        case .gemini:
            return appSupportRoot.appendingPathComponent("Config", isDirectory: true)
        case .agy, .claudeCode, .codex:
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/antigravity", isDirectory: true)
        }
    }

    /// 代理配置全局唯一，不随 activeApp 变化
    /// MITM 网关的自签 CA（Node.js / Go 都需要信任它才会走 18081）
    static var goproxyCAFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/antigravity/goproxy_ca.pem")
    }

    /// 系统根证书 + goproxy CA 合并包。`SSL_CERT_FILE` 对 Go 是**替换**而非追加，
    /// 只指向自签 CA 会让所有真实 HTTPS 端点证书校验失败。
    static var combinedCAFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/antigravity/combined_ca.pem")
    }

    static var userProxyConfigFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/antigravity/proxy_config.json")
    }

    /// 模型路由配置（单一文件，供 Go proxy 读取）
    static var userModelRoutingConfigFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/antigravity/model_routing.json")
    }

    static let patchLogFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/antigravity/patch.log")

    // MARK: - CLI-specific paths

    static var patchedCLIDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(activeApp.cliPatchedDirRelativePath, isDirectory: true)
    }

    static var patchedCLIRealBinary: URL {
        patchedCLIDir.appendingPathComponent(activeApp.cliRealBinaryName)
    }

    static var patchedCLIWrapper: URL {
        patchedCLIDir.appendingPathComponent(activeApp.patchedName)
    }

    static var patchedCLIDylib: URL {
        patchedCLIDir.appendingPathComponent("libAntigravityTun.dylib")
    }

    static var patchedCLIConfig: URL {
        patchedCLIDir.appendingPathComponent("proxy_config.json")
    }

    static var patchedCLIEntitlements: URL {
        patchedCLIDir.appendingPathComponent("entitlements.plist")
    }

    static var requiredRuntimeDirectories: [URL] {
        var dirs: [URL] = [
            appSupportRoot,
            metadataRoot,
            userConfigRoot,
            patchLogFile.deletingLastPathComponent()
        ]
        if activeApp.targetType == .cliBinary {
            dirs.append(patchedCLIDir)
        }
        return dirs
    }

    static func ensureRuntimeDirectoriesExist() throws {
        let fm = FileManager.default
        for directory in requiredRuntimeDirectories {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static var bundledDylib: URL {
        bundleResourceURL(named: "libAntigravityTun", withExtension: "dylib")
            ?? launcherRoot.appendingPathComponent("Resources/libAntigravityTun.dylib")
    }

    static var bundledEntitlements: URL {
        bundleResourceURL(named: "entitlements", withExtension: "plist")
            ?? launcherRoot.appendingPathComponent("Resources/entitlements.plist")
    }

    static var bundledProxyConfigTemplate: URL {
        bundleResourceURL(named: "proxy_config.template", withExtension: "json")
            ?? launcherRoot.appendingPathComponent("Resources/proxy_config.template.json")
    }

    static var bundledGoogleOAuthClientConfig: URL {
        bundleResourceURL(named: "google_oauth_client", withExtension: "json")
            ?? launcherRoot.appendingPathComponent("Resources/google_oauth_client.json")
    }

    static var fallbackProxyRepoDylib: URL {
        siblingProxyRepoRoot.appendingPathComponent("libAntigravityTun.dylib")
    }

    static var fallbackProxyRepoEntitlements: URL {
        siblingProxyRepoRoot.appendingPathComponent("entitlements.plist")
    }

    static var legacyScriptsRoot: URL {
        projectRoot.appendingPathComponent("legacy_scripts", isDirectory: true)
    }

    static var legacyScriptsDylib: URL {
        legacyScriptsRoot.appendingPathComponent("libAntigravityTun.dylib")
    }

    static var legacyScriptsEntitlements: URL {
        legacyScriptsRoot.appendingPathComponent("entitlements.plist")
    }

    static var runtimeDylibCandidates: [URL] {
        [
            bundledDylib,
            legacyScriptsDylib,
            fallbackProxyRepoDylib
        ]
    }

    static var entitlementsCandidates: [URL] {
        [
            bundledEntitlements,
            legacyScriptsEntitlements,
            fallbackProxyRepoEntitlements
        ]
    }
}
