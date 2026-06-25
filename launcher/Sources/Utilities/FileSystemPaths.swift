import Foundation

enum FileSystemPaths {
    private static var sourceFileURL: URL {
#if DEBUG
        URL(fileURLWithPath: #filePath)
#else
        Bundle.main.bundleURL.appendingPathComponent("Sources/Utilities/FileSystemPaths.swift")
#endif
    }

    private static var appBundleResourceRoot: URL? {
        Bundle.main.resourceURL
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

    static var activeApp: TargetApp = .antigravity

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
    static var userProxyConfigFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/antigravity/proxy_config.json")
    }

    /// 模型路由配置全局唯一，不随 activeApp 变化
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
