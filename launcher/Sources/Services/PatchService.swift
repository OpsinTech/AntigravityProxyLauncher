import Foundation
import CryptoKit

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

        if FileSystemPaths.activeApp.targetType == .cliBinary {
            try preparePatchedCLI(onProgress: onProgress)
            return
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

    // MARK: - CLI patching

    private func preparePatchedCLI(onProgress: ((String) -> Void)? = nil) throws {
        PatchLogWriter.beginSession()

        let fm = FileManager.default
        let cliDir = FileSystemPaths.patchedCLIDir
        let realBinary = FileSystemPaths.patchedCLIRealBinary
        let wrapper = FileSystemPaths.patchedCLIWrapper
        let dylibDest = FileSystemPaths.patchedCLIDylib
        let entitlementsDest = FileSystemPaths.patchedCLIEntitlements
        let userSymlink = FileSystemPaths.targetApp
        let backupPath = userSymlink.path + ".original"
        var symlinkReplaced = false
        var wrapperCreated = false

        // Rollback helper: restore the user-facing symlink from .original backup
        func rollbackCLI() {
            report("CLI 修复失败，正在回滚...", onProgress: onProgress)
            if wrapperCreated, fm.fileExists(atPath: wrapper.path) {
                try? fm.removeItem(at: wrapper)
            }
            if symlinkReplaced {
                if fm.fileExists(atPath: userSymlink.path) || ((try? userSymlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) {
                    try? fm.removeItem(at: userSymlink)
                }
                if fm.fileExists(atPath: backupPath) && fm.isExecutableFile(atPath: backupPath) {
                    try? fm.copyItem(at: URL(fileURLWithPath: backupPath), to: userSymlink)
                    report("已还原 \(FileSystemPaths.activeApp.displayName) 原始二进制", onProgress: onProgress)
                } else {
                    report("⚠️ 无法还原原始二进制，请手动恢复 \(backupPath) -> \(userSymlink.path)", onProgress: onProgress)
                }
            }
            // Clean up partial CLI directory but keep .original backup
            if fm.fileExists(atPath: cliDir.path) {
                try? fm.removeItem(at: cliDir)
            }
        }

        do {
            // Resolve the real source binary, regardless of symlink state.
            // The user-facing path may already be a symlink from a previous patch.
            let resolvedSource: URL = {
                let isSymlink = (try? userSymlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                if isSymlink {
                    let target = userSymlink.resolvingSymlinksInPath()
                    // If it points to our own wrapper, look for a backup or the real binary
                    if target.path == wrapper.path {
                        let backup = URL(fileURLWithPath: userSymlink.path + ".original")
                        if fm.fileExists(atPath: backup.path) && fm.isExecutableFile(atPath: backup.path) {
                            return backup
                        }
                    }
                    // Follow the symlink to the actual file
                    if fm.fileExists(atPath: target.path) && fm.isExecutableFile(atPath: target.path) {
                        return target
                    }
                }
                return userSymlink
            }()

            guard fm.isExecutableFile(atPath: resolvedSource.path) else {
                throw PatchServiceError.runtimeAssetMissing("\(FileSystemPaths.activeApp.displayName) 原始二进制不可执行: \(resolvedSource.path)")
            }

            // Capture version now — before we change the symlink and dylib injection kicks in
            let capturedVersion = detectInstalledTargetApp()?.version ?? "unknown"

            // 1. Create directory
            report("创建 CLI 修复目录: \(cliDir.path)", onProgress: onProgress)
            try fm.createDirectory(at: cliDir, withIntermediateDirectories: true)

            // 2. Copy original binary (from resolved real source, not symlink)
            report("复制 \(FileSystemPaths.activeApp.displayName) 二进制到 \(realBinary.path)", onProgress: onProgress)
            if fm.fileExists(atPath: realBinary.path) {
                let isExistingSymlink = (try? realBinary.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                let isExistingRealBinary = !isExistingSymlink
                // If the existing real binary exists, reuse it
                if isExistingRealBinary && fm.isExecutableFile(atPath: realBinary.path) {
                    report("\(realBinary.lastPathComponent) 已存在，跳过复制", onProgress: onProgress)
                } else {
                    try fm.removeItem(at: realBinary)
                }
            }
            if !fm.fileExists(atPath: realBinary.path) {
                try fm.copyItem(at: resolvedSource, to: realBinary)
            }

            // 3. Copy dylib
            let dylibSource = try resolveDylibSource()
            report("复制 dylib: \(dylibSource.path)", onProgress: onProgress)
            try copyFileReplacingExisting(from: dylibSource, to: dylibDest)

            // 4. Copy entitlements
            let entitlementsSource = try resolveEntitlementsSource()
            report("复制 entitlements.plist", onProgress: onProgress)
            try copyFileReplacingExisting(from: entitlementsSource, to: entitlementsDest)

            // 5. Ensure proxy config exists (global, shared by all apps)
            let configSource = try resolveProxyConfigSource()
            report("代理配置文件: \(configSource.path)", onProgress: onProgress)

            // 6. Re-sign the real binary
            report("重签名 \(realBinary.lastPathComponent)", onProgress: onProgress)
            try signingService.signSingleBinary(at: realBinary, entitlementsURL: entitlementsDest)

            // 7. Create wrapper script
            report("生成 wrapper 脚本: \(wrapper.path)", onProgress: onProgress)
            if fm.fileExists(atPath: wrapper.path) {
                try fm.removeItem(at: wrapper)
            }
            let realBinaryName = FileSystemPaths.activeApp.cliRealBinaryName
            let wrapperContent = """
            #!/bin/bash
            # Resolve the real path of this script (follow symlinks) so the sibling
            # binary is found regardless of how the wrapper is invoked.
            SCRIPT_PATH="$0"
            while [ -L "$SCRIPT_PATH" ]; do
                TARGET="$(readlink "$SCRIPT_PATH")"
                case "$TARGET" in
                    /*) SCRIPT_PATH="$TARGET" ;;
                    *)  SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/$TARGET" ;;
                esac
            done
            SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
            export DYLD_INSERT_LIBRARIES="$SCRIPT_DIR/libAntigravityTun.dylib"
            export ANTIGRAVITY_CONFIG="$HOME/.config/antigravity/proxy_config.json"
            # Redirect dylib logs to file to keep stderr clean for CLI output
            export ANTIGRAVITY_LOG_FILE=1
            export ANTIGRAVITY_LOG_PATH="$HOME/.config/antigravity/antigravity_proxy.$$.log"
            exec "$SCRIPT_DIR/\(realBinaryName)" "$@"
            """
            try wrapperContent.write(to: wrapper, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            wrapperCreated = true

            // 8. Update user-facing symlink — always preserve the real binary as .original
            report("更新符号链接: \(userSymlink.path) -> \(wrapper.path)", onProgress: onProgress)
            let isSymlink = (try? userSymlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false

            // Ensure a .original backup of the real binary exists BEFORE we replace the symlink
            if !fm.fileExists(atPath: backupPath) {
                if isSymlink {
                    // Resolve symlink to find the real binary and back that up
                    let resolved = userSymlink.resolvingSymlinksInPath()
                    if resolved.path != wrapper.path,
                       fm.fileExists(atPath: resolved.path),
                       fm.isExecutableFile(atPath: resolved.path) {
                        try fm.copyItem(at: resolved, to: URL(fileURLWithPath: backupPath))
                        report("已备份原始二进制 (从 symlink 解析): \(backupPath)", onProgress: onProgress)
                    } else if fm.isExecutableFile(atPath: resolvedSource.path)
                                && resolvedSource.path != wrapper.path {
                        try fm.copyItem(at: resolvedSource, to: URL(fileURLWithPath: backupPath))
                        report("已备份原始二进制 (从 resolvedSource): \(backupPath)", onProgress: onProgress)
                    }
                } else if fm.isExecutableFile(atPath: userSymlink.path) {
                    try fm.copyItem(at: userSymlink, to: URL(fileURLWithPath: backupPath))
                    report("已备份原始二进制: \(backupPath)", onProgress: onProgress)
                }
            }

            // Verify backup exists before proceeding to the destructive step
            guard fm.fileExists(atPath: backupPath) && fm.isExecutableFile(atPath: backupPath) else {
                throw PatchServiceError.runtimeAssetMissing("备份原始二进制失败，中止修复以保护原文件")
            }

            // Remove existing symlink or file and create new symlink (destructive step)
            if fm.fileExists(atPath: userSymlink.path) || isSymlink {
                try fm.removeItem(at: userSymlink)
            }
            symlinkReplaced = true
            try fm.createSymbolicLink(at: userSymlink, withDestinationURL: wrapper)

            // 9. Persist metadata (use version captured before patching)
            report("写入 patch 元数据", onProgress: onProgress)
            try persistPatchMetadata(targetVersion: capturedVersion)
        } catch {
            rollbackCLI()
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

        // Keep helper processes portable: each Helper resolves @executable_path/../Resources
        // relative to its own bundle, so we mirror the dylib into helper Resources.
        for helperResourceDir in helperResourceDirectories() {
            try fm.createDirectory(at: helperResourceDir, withIntermediateDirectories: true)
            try copyFileReplacingExisting(
                from: dylibSource,
                to: helperResourceDir.appendingPathComponent("libAntigravityTun.dylib")
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
            "ANTIGRAVITY_CONFIG": FileSystemPaths.userProxyConfigFile.path
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
        let dest = FileSystemPaths.userProxyConfigFile
        let destDir = dest.deletingLastPathComponent()

        if fm.fileExists(atPath: dest.path) {
            return dest
        }

        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: FileSystemPaths.bundledProxyConfigTemplate.path) {
            try copyFileReplacingExisting(from: FileSystemPaths.bundledProxyConfigTemplate, to: dest)
            return dest
        }

        let data = try JSONEncoder.pretty.encode(ProxyConfig.default)
        try data.write(to: dest)
        return dest
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

    func persistPatchMetadata(targetVersion: String? = nil) throws {
        try FileManager.default.createDirectory(
            at: FileSystemPaths.metadataRoot,
            withIntermediateDirectories: true
        )

        let appVersion: String
        if let targetVersion, !targetVersion.isEmpty {
            appVersion = targetVersion
        } else {
            appVersion = detectInstalledTargetApp()?.version ?? "unknown"
        }

        // Compute real checksums for integrity verification
        let dylibChecksum: String = {
            if let data = try? Data(contentsOf: FileSystemPaths.patchedCLIDylib) {
                return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            }
            // For App Bundle, dylib is inside the bundle
            let dylibPath = FileSystemPaths.patchedApp
                .appendingPathComponent("Contents/Resources/libAntigravityTun.dylib")
            if let data = try? Data(contentsOf: dylibPath) {
                return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            }
            return "unavailable"
        }()

        let configChecksum: String = {
            if let data = try? Data(contentsOf: FileSystemPaths.userProxyConfigFile) {
                return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            }
            return "unavailable"
        }()

        // Load license info if available
        let licenseInfo = try? LicenseService().loadLocal()
        let licenseExpiresAt = licenseInfo?.expiresAt
        let licenseMachineId = licenseInfo?.machineId
        let licenseHMAC: String? = {
            if let expiresAt = licenseExpiresAt, let machineId = licenseMachineId {
                return PatchMetadata.computeLicenseHMAC(expiresAt: expiresAt, machineId: machineId)
            }
            return nil
        }()

        let metadata = PatchMetadata(
            launcherVersion: LauncherAppState.resolveLauncherVersion(),
            targetVersion: appVersion,
            patchedAt: Date(),
            dylibChecksum: dylibChecksum,
            configChecksum: configChecksum,
            licenseExpiresAt: licenseExpiresAt,
            licenseMachineId: licenseMachineId,
            licenseHMAC: licenseHMAC
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
