import Foundation

enum PatchServiceError: Error {
    case targetAppMissing
    case copyFailed
    case runtimeAssetMissing(String)
    case plistWriteFailed
    case rollbackFailed(String)
}

extension PatchServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .targetAppMissing:
            return "未找到 \(FileSystemPaths.targetApp.path)"
        case .copyFailed:
            return "复制目标 App 失败"
        case .runtimeAssetMissing(let name):
            return "缺少运行时资源: \(name)"
        case .plistWriteFailed:
            return "写入 Info.plist 失败"
        case .rollbackFailed(let message):
            return "修复失败且回滚失败: \(message)"
        }
    }
}

final class PatchService {
    private let detection = AppDetectionService()
    private let signingService = SigningService()

    private func report(_ message: String, onProgress: ((String) -> Void)?) {
        onProgress?(message)
        PatchLogWriter.append(message)
    }

    func detectInstalledTargetApp() -> AppInfo? {
        detection.detectInstalledTargetApp()
    }

    func preparePatchedBundle(onProgress: ((String) -> Void)? = nil) throws {
        guard detectInstalledTargetApp() != nil else {
            throw PatchServiceError.targetAppMissing
        }

        PatchLogWriter.beginSession()

        let fm = FileManager.default
        let destination = FileSystemPaths.patchedApp
        let destinationParent = destination.deletingLastPathComponent()

        report("创建目标目录: \(destinationParent.path)", onProgress: onProgress)
        try fm.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        if fm.fileExists(atPath: destination.path) {
            report("清理旧修复包: \(destination.path)", onProgress: onProgress)
            try fm.removeItem(at: destination)
        }

        do {
            do {
                report("复制原版应用到: \(destination.path)", onProgress: onProgress)
                try fm.copyItem(at: FileSystemPaths.targetApp, to: destination)
            } catch {
                throw PatchServiceError.copyFailed
            }

            report("清理扩展属性 xattr", onProgress: onProgress)
            try clearExtendedAttributes()
            report("嵌入运行时资源", onProgress: onProgress)
            try embedRuntimeAssets()
            report("写入 Info.plist", onProgress: onProgress)
            try rewriteInfoPlist()
            report("写入 patch 元数据", onProgress: onProgress)
            try persistPatchMetadata()
            report("签名前 preflight 检查", onProgress: onProgress)
            try signingService.preflight()
            report("执行 inside-out 重签名", onProgress: onProgress)
            try resignBundle(onProgress: onProgress)
            
            // 修复完成后自动清理隔离属性，避免 Gatekeeper 提示
            report("清理修复包隔离属性 (xattr)", onProgress: onProgress)
            try clearExtendedAttributesAfterSigning()
            
            // 针对 Gemini 应用，额外处理钥匙串访问权限
            if FileSystemPaths.activeApp == .gemini {
                report("配置 Gemini 特殊权限", onProgress: onProgress)
                try configureGeminiSpecialPermissions()
            }
        } catch {
            report("检测到失败，执行自动回滚", onProgress: onProgress)
            do {
                try rollbackPatchedBundleIfNeeded()
                report("回滚完成", onProgress: onProgress)
            } catch {
                throw PatchServiceError.rollbackFailed(error.localizedDescription)
            }
            throw error
        }
    }

    private func rollbackPatchedBundleIfNeeded() throws {
        let fm = FileManager.default
        let destination = FileSystemPaths.patchedApp
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
    }

    func embedRuntimeAssets() throws {
        let fm = FileManager.default
        let resources = FileSystemPaths.patchedApp.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let dylibDestination = resources.appendingPathComponent("libAntigravityTun.dylib")
        let dylibSource = try resolveDylibSource()
        try copyFileReplacingExisting(from: dylibSource, to: dylibDestination)

        let configURL = resources.appendingPathComponent("proxy_config.json")
        let configSource = try resolveProxyConfigSource()
        try copyFileReplacingExisting(from: configSource, to: configURL)

        // Keep helper processes portable: each Helper resolves @executable_path/../Resources
        // relative to its own bundle, so we mirror runtime assets into helper Resources.
        for helperResourceDir in helperResourceDirectories() {
            try fm.createDirectory(at: helperResourceDir, withIntermediateDirectories: true)
            try copyFileReplacingExisting(
                from: dylibSource,
                to: helperResourceDir.appendingPathComponent("libAntigravityTun.dylib")
            )
            try copyFileReplacingExisting(
                from: configSource,
                to: helperResourceDir.appendingPathComponent("proxy_config.json")
            )
        }
    }

    func rewriteInfoPlist() throws {
        let infoURL = FileSystemPaths.patchedApp.appendingPathComponent("Contents/Info.plist")
        guard var dict = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw PatchServiceError.plistWriteFailed
        }

        dict["SUEnableAutomaticChecks"] = false
        dict["LSEnvironment"] = [
            "DYLD_INSERT_LIBRARIES": "@executable_path/../Resources/libAntigravityTun.dylib",
            "ANTIGRAVITY_CONFIG": "@executable_path/../Resources/proxy_config.json"
        ]

        let nsDict = dict as NSDictionary
        if !nsDict.write(to: infoURL, atomically: true) {
            throw PatchServiceError.plistWriteFailed
        }
    }

    func resignBundle(onProgress: ((String) -> Void)? = nil) throws {
        let entitlements = try resolveEntitlementsSource()
        try signingService.resignBundleInsideOut(
            at: FileSystemPaths.patchedApp,
            entitlementsURL: entitlements,
            onProgress: onProgress
        )
    }

    private func clearExtendedAttributes() throws {
        _ = try CommandRunner.run(
            "/usr/bin/xattr",
            ["-cr", FileSystemPaths.patchedApp.path]
        )
    }
    
    /// 签名后清理隔离属性，确保修复后的应用不会被 Gatekeeper 拦截
    private func clearExtendedAttributesAfterSigning() throws {
        let appPath = FileSystemPaths.patchedApp.path

        // xattr -cr 递归清理整个 app bundle 的所有扩展属性（单次调用）
        _ = try? CommandRunner.run("/usr/bin/xattr", ["-cr", appPath])
    }
    
    /// 配置 Gemini 应用的特殊权限
    private func configureGeminiSpecialPermissions() throws {
        let appPath = FileSystemPaths.patchedApp.path
        let bundleID = FileSystemPaths.activeApp.bundleIdentifier
        
        // 1. 重置 TCC 权限数据库中的旧记录，避免冲突
        _ = try? CommandRunner.run("/usr/bin/tccutil", ["reset", "All", bundleID])
        _ = try? CommandRunner.run("/usr/bin/tccutil", ["reset", "All", "com.google.GeminiMacOS"])
        
        // 2. 针对钥匙串访问权限，清理旧的钥匙串条目
        // 注意：这需要用户首次启动时输入密码，但之后就不会再提示
        let keychainIdentities = [
            "Gemini",
            "com.google.GeminiMacOS",
            "Gemini_Unlocked"
        ]
        
        for identity in keychainIdentities {
            // 尝试删除可能冲突的钥匙串条目
            _ = try? CommandRunner.run(
                "/usr/bin/security",
                ["delete-generic-password", "-s", identity, "-a", identity]
            )
        }
        
        // 3. 设置应用包权限，确保有执行权限
        _ = try? CommandRunner.run("/bin/chmod", ["-R", "+x", appPath])
        
        // 4. 清理 LaunchServices 缓存，确保系统识别新的签名
        _ = try? CommandRunner.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", 
                                     ["-f", "-r", appPath])
    }

    private func resolveDylibSource() throws -> URL {
        let fm = FileManager.default
        for candidate in FileSystemPaths.runtimeDylibCandidates {
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw PatchServiceError.runtimeAssetMissing("libAntigravityTun.dylib")
    }

    private func resolveEntitlementsSource() throws -> URL {
        let fm = FileManager.default
        for candidate in FileSystemPaths.entitlementsCandidates {
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw PatchServiceError.runtimeAssetMissing("entitlements.plist")
    }

    private func resolveProxyConfigSource() throws -> URL {
        let fm = FileManager.default

        if fm.fileExists(atPath: FileSystemPaths.userProxyConfigFile.path) {
            return FileSystemPaths.userProxyConfigFile
        }

        if fm.fileExists(atPath: FileSystemPaths.bundledProxyConfigTemplate.path) {
            try fm.createDirectory(at: FileSystemPaths.userConfigRoot, withIntermediateDirectories: true)
            try copyFileReplacingExisting(
                from: FileSystemPaths.bundledProxyConfigTemplate,
                to: FileSystemPaths.userProxyConfigFile
            )
            return FileSystemPaths.userProxyConfigFile
        }

        try fm.createDirectory(at: FileSystemPaths.userConfigRoot, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(ProxyConfig.default)
        try data.write(to: FileSystemPaths.userProxyConfigFile)
        return FileSystemPaths.userProxyConfigFile
    }

    private func copyFileReplacingExisting(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    private func helperResourceDirectories() -> [URL] {
        let frameworks = FileSystemPaths.patchedApp
            .appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: frameworks,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children
            .filter { $0.pathExtension == "app" && $0.lastPathComponent.contains("Helper") }
            .map { $0.appendingPathComponent("Contents/Resources", isDirectory: true) }
    }

    func persistPatchMetadata() throws {
        try FileManager.default.createDirectory(
            at: FileSystemPaths.metadataRoot,
            withIntermediateDirectories: true
        )

        let appVersion = detectInstalledTargetApp()?.version ?? "unknown"
        let metadata = PatchMetadata(
            launcherVersion: "0.1.0",
            targetVersion: appVersion,
            patchedAt: Date(),
            dylibChecksum: "pending",
            configChecksum: "pending"
        )

        let safeVersion = appVersion.replacingOccurrences(of: "/", with: "_")
        let metadataURL = FileSystemPaths.metadataRoot
            .appendingPathComponent("launcher_patch_metadata_\(safeVersion).json")

        let data = try JSONEncoder.pretty.encode(metadata)
        try data.write(to: metadataURL)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
