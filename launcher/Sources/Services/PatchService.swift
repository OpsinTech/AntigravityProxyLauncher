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
            report("签名前 preflight 检查", onProgress: onProgress)
            try signingService.preflight()
            report("执行 inside-out 重签名", onProgress: onProgress)
            try resignBundle(onProgress: onProgress)
            // 元数据要在签名之后写：codesign 会改写 dylib 内容，签名前记录的校验值
            // 与最终文件永远对不上，健康检查就会一直报「需要修复」。
            report("写入 patch 元数据", onProgress: onProgress)
            try persistPatchMetadata()
            
            // 修复完成后自动清理隔离属性，避免 Gatekeeper 提示
            report("清理修复包隔离属性 (xattr)", onProgress: onProgress)
            try clearExtendedAttributesAfterSigning()
            
            // 针对 Gemini 应用，额外处理钥匙串访问权限
            if FileSystemPaths.activeApp == .gemini {
                report("配置 Gemini 特殊权限", onProgress: onProgress)
                try configureGeminiSpecialPermissions()

                // Gemini 用 Network.framework 在框架内部建连，dylib 的 connect hook 拦不到，
                // 只能把域名解析到 127.0.0.1 再由本地 SNI 分流器接管。缺了这一步，
                // 应用能开窗口但所有 Google 请求都会 code=14。
                report("安装本地 SNI 分流器", onProgress: onProgress)
                do {
                    try SNIRedirectService().installIfNeeded { [weak self] msg in
                        self?.report(msg, onProgress: onProgress)
                    }
                } catch {
                    report("⚠️ SNI 分流器未就绪：\(error.localizedDescription)", onProgress: onProgress)
                }
            } else {
                // 其它 App（Antigravity 系列）依赖 FakeIP 做域名级隧道。
                // 注意：这里只确保 FakeIP 开启，绝不清理排除名单 —— 否则会顺手
                // 删掉 Gemini 的排除项，让 Gemini 重新掉回 code=14。
                report("确认 FakeIP 隧道配置", onProgress: onProgress)
                try? FakeIPBypassService.applyForTunnelApps()
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
            let wrapperEnvExports = FileSystemPaths.activeApp.cliWrapperEnvironment
                .sorted { $0.key < $1.key }
                .map { "export \($0.key)=\"\($0.value)\"" }
                .joined(separator: "\n")
            let wrapperContent = """
            #!/bin/bash
            # antigravity-proxy-wrapper — generated by Antigravity Proxy Launcher.
            # Regenerate with "修复"; do not edit by hand.
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
            # Absolute path: DYLD_INSERT_LIBRARIES must not depend on the caller's cwd.
            SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

            # Keep the bundled auto-updater out of this directory: it replaces the
            # binary with an official build whose hardened runtime makes macOS
            # ignore DYLD_INSERT_LIBRARIES, silently killing the tun injection.
            \(wrapperEnvExports)

            # Go 组件只认环境变量（DYLD 注入对它无效），所以不能把代理清空了事：
            # 清掉终端里来源不明的设置后，统一指向本地 MITM 网关 18081。
            unset ALL_PROXY all_proxy
            export HTTPS_PROXY="http://127.0.0.1:18081"
            export HTTP_PROXY="http://127.0.0.1:18081"
            export NO_PROXY="127.0.0.1,localhost"

            # Self-heal: if the real binary was replaced behind our back (manual update,
            # or an updater that ignored the switch above), re-apply our ad-hoc signature
            # so the injected dylib is actually loaded.
            if [ -x "$SCRIPT_DIR/\(realBinaryName)" ] && [ -f "$SCRIPT_DIR/entitlements.plist" ]; then
                if ! codesign -d --entitlements - "$SCRIPT_DIR/\(realBinaryName)" 2>/dev/null | grep -q "disable-library-validation"; then
                    codesign --force --options runtime --sign - --entitlements "$SCRIPT_DIR/entitlements.plist" "$SCRIPT_DIR/\(realBinaryName)" >/dev/null 2>&1 || echo "[agy-proxy] 警告: 重签名失败，DYLD 注入可能不生效" >&2
                fi
            fi

            export DYLD_INSERT_LIBRARIES="$SCRIPT_DIR/libAntigravityTun.dylib"
            export ANTIGRAVITY_CONFIG="$HOME/.config/antigravity/proxy_config.json"
            # Trust MITM proxy CA bundle for Go binaries and Node.js
            if [ -f "$HOME/.config/antigravity/combined_ca.pem" ]; then
                export SSL_CERT_FILE="$HOME/.config/antigravity/combined_ca.pem"
            fi
            if [ -f "$HOME/.config/antigravity/goproxy_ca.pem" ]; then
                export NODE_EXTRA_CA_CERTS="$HOME/.config/antigravity/goproxy_ca.pem"
            fi
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

        // 辅助副本：注入本身走主包绝对路径（见 rewriteInfoPlist），这里额外把 dylib
        // 镜像进各 Helper 的 Resources，兼容历史上按相对路径解析的 helper 与手动排查。
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
        // 必须写绝对路径：`@executable_path/../Resources/...` 只在主可执行文件的
        // 层级成立。helper 进程（GeminiAppLauncher、Electron Helper、language_server）
        // 继承 DYLD_INSERT_LIBRARIES 后会把路径拼成
        // `.../Contents/Resources/Resources/libAntigravityTun.dylib`，dyld 找不到库
        // 就 abort —— 用户看到的就是「点开没窗口、后台日志里子进程反复崩溃」。
        let dylibPath = FileSystemPaths.patchedApp
            .appendingPathComponent("Contents/Resources/libAntigravityTun.dylib")
            .path
        var launchEnvironment: [String: String] = [
            "DYLD_INSERT_LIBRARIES": dylibPath,
            "ANTIGRAVITY_CONFIG": FileSystemPaths.userProxyConfigFile.path
        ]

        // Electron 目标会拉起 Go 写的组件（language_server、内置 agy），这些程序
        // 是 hardened runtime 的 Google 签名二进制，DYLD 注入不进去，只认环境变量。
        // 写进 Info.plist 才能保证「从 Dock 直接双击」也带上代理，而不只是经由
        // Launcher 启动时才正常。
        if FileSystemPaths.activeApp == .antigravity || FileSystemPaths.activeApp == .antigravityIDE {
            launchEnvironment["HTTPS_PROXY"] = "http://127.0.0.1:18081"
            launchEnvironment["HTTP_PROXY"] = "http://127.0.0.1:18081"
            launchEnvironment["NO_PROXY"] = "127.0.0.1,localhost"
            launchEnvironment["SSL_CERT_FILE"] = FileSystemPaths.combinedCAFile.path
            launchEnvironment["NODE_EXTRA_CA_CERTS"] = FileSystemPaths.goproxyCAFile.path
        }

        dict["LSEnvironment"] = launchEnvironment

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

        // 0. Gemini 的 gRPC 传输层走 Network.framework，其 connect() 发生在 dyld
        //    共享缓存内部，DYLD_INTERPOSE(my_connect, connect) 拦不到。若 dylib 仍然把
        //    域名解析成 FakeIP，这些连接会直接拨 198.18.x.x —— 该网段又被 mihomo TUN
        //    的 `IP-CIDR,198.18.0.0/15,DIRECT` 规则吞掉，于是连接秒失败，网络层报
        //    iRPC code=14 (UNAVAILABLE)，App 卡在 isRecoveringFromError、窗口不显示。
        //    现行方案：把 Gemini 的域名解析到本地回环（fake_ip.bypass_cidr，默认
        //    127.0.0.1/32），再由 root 的 sni_redirect 守护进程按 TLS SNI 还原目标域名、
        //    经上游 SOCKS5 做纯隧道转发。所以这里把 Gemini 排除出 FakeIP 名单，
        //    而不是让它走真实地址。
        try FakeIPBypassService.applyForGemini()
        report("已将 Gemini 加入 FakeIP 排除名单（不影响 Antigravity / CLI）", onProgress: nil)

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

        // Compute real checksums for integrity verification.
        // 必须按目标类型取对应文件：之前无条件先读 CLI 的 dylib，导致所有 App Bundle
        // 目标记录的都是 CLI 那份的校验值，健康检查每次比对都判为漂移 → 无限要求修复。
        let dylibChecksum: String = {
            let dylibPath: URL
            switch FileSystemPaths.activeApp.targetType {
            case .cliBinary:
                dylibPath = FileSystemPaths.patchedCLIDylib
            case .appBundle:
                dylibPath = FileSystemPaths.patchedApp
                    .appendingPathComponent("Contents/Resources/libAntigravityTun.dylib")
            }
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

        let metadata = PatchMetadata(
            launcherVersion: LauncherAppState.resolveLauncherVersion(),
            targetVersion: appVersion,
            patchedAt: Date(),
            dylibChecksum: dylibChecksum,
            configChecksum: configChecksum
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
