import Foundation
import CryptoKit

enum PatchedAppHealth {
    case missing
    case ready
    case outdated
    case repairRequired(String)
}

struct PatchedAppHealthService {
    func evaluate(targetVersion: String) -> PatchedAppHealth {
        if FileSystemPaths.activeApp.targetType == .cliBinary {
            return evaluateCLI(targetVersion: targetVersion)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: FileSystemPaths.patchedApp.path) else {
            return .missing
        }

        guard let metadata = latestMetadata() else {
            return .repairRequired("未找到 patch 元数据，请重新修复。")
        }

        if metadata.targetVersion != targetVersion {
            return .outdated
        }

        let dylib = FileSystemPaths.patchedApp
            .appendingPathComponent("Contents/Resources/libAntigravityTun.dylib")

        guard fm.fileExists(atPath: dylib.path) else {
            return .repairRequired("修复包缺少 dylib，请重新修复。")
        }

        if let drift = dylibDriftMessage(bundleDylib: dylib, expected: metadata.dylibChecksum) {
            return .repairRequired(drift)
        }

        if let injectionIssue = injectionPathIssue() {
            return .repairRequired(injectionIssue)
        }

        // Gemini 走的不是 FakeIP + connect hook，而是「域名解析到 127.0.0.1 + 本地
        // SNI 分流器」。分流器没装或没跑起来时，应用能启动但所有请求都会 code=14，
        // 所以这里必须一起校验。
        if FileSystemPaths.activeApp == .gemini {
            switch SNIRedirectService().status() {
            case .running:
                // 分流器在跑，但 plist 里的上游还是旧端口（用户改过代理配置）：
                // 这种情况下 Gemini 能启动却连不上网，必须提示重新修复。
                if SNIRedirectService.plistUpstreamIsStale() {
                    return .repairRequired("本地 SNI 分流器的上游代理与当前配置不一致，请重新修复。")
                }
                break
            case .notInstalled:
                return .repairRequired("本地 SNI 分流器未安装（Gemini 会卡在 code=14），请重新修复。")
            case .installedNotRunning:
                return .repairRequired("本地 SNI 分流器未运行，请重新修复或重启系统。")
            case .portOccupied:
                return .repairRequired("127.0.0.1:443 被其它程序占用，SNI 分流器无法启动。")
            }
        }

        return .ready
    }

    /// LSEnvironment 里记录的是 dylib 绝对路径。老版本写的是
    /// `@executable_path/../Resources/...`，helper 进程继承后会解析失败并 abort；
    /// 新版 app 若被搬动/重装，绝对路径也会失效。两种情况都需要重新修复。
    private func injectionPathIssue() -> String? {
        let infoPlist = FileSystemPaths.patchedApp.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: infoPlist),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = plist as? [String: Any],
            let env = dict["LSEnvironment"] as? [String: String],
            let injected = env["DYLD_INSERT_LIBRARIES"]
        else {
            return "修复包缺少注入配置，请重新修复。"
        }

        if injected.hasPrefix("@executable_path") {
            return "修复包使用了旧的相对路径注入（helper 进程会崩溃），请重新修复。"
        }

        if !FileManager.default.fileExists(atPath: injected) {
            return "注入路径已失效（修复包被移动或重装），请重新修复。"
        }

        return nil
    }

    private func evaluateCLI(targetVersion: String) -> PatchedAppHealth {
        let fm = FileManager.default
        let wrapper = FileSystemPaths.patchedCLIWrapper
        let realBinary = FileSystemPaths.patchedCLIRealBinary
        let dylib = FileSystemPaths.patchedCLIDylib

        guard fm.fileExists(atPath: wrapper.path) else { return .missing }

        guard let metadata = latestMetadata() else {
            return .repairRequired("未找到 patch 元数据，请重新修复。")
        }

        if metadata.targetVersion != targetVersion {
            return .outdated
        }

        guard fm.fileExists(atPath: realBinary.path),
              fm.fileExists(atPath: dylib.path) else {
            return .repairRequired("修复目录缺少关键资源，请重新修复。")
        }

        guard fm.isExecutableFile(atPath: wrapper.path) else {
            return .repairRequired("wrapper 脚本不可执行，请重新修复。")
        }

        // The CLI's bundled auto-updater (or a manual reinstall) can overwrite
        // `<dir>/agy` with an official build. Official builds are hardened and
        // ignore DYLD_INSERT_LIBRARIES, so the proxy silently disappears and the
        // CLI dials Google directly (login fails with "token exchange failed:
        // i/o timeout"). Detect both halves of that drift.
        guard isProxyWrapper(at: wrapper) else {
            return .repairRequired("CLI 入口已被官方自动更新覆盖，注入已失效，请重新修复。")
        }

        guard binaryHasInjectionEntitlement(at: realBinary) else {
            return .repairRequired("CLI 二进制签名已被覆盖，系统会忽略 DYLD 注入，请重新修复。")
        }

        if let drift = dylibDriftMessage(bundleDylib: dylib, expected: metadata.dylibChecksum) {
            return .repairRequired(drift)
        }

        return .ready
    }

    /// Launcher 升级会带来新的 dylib，但「修复包」里的 dylib 是上次修复时复制的。
    /// 只比较目标 App 版本号不够：老用户升级 Launcher 后会被判定 ready，实际仍在跑
    /// 旧 dylib（新修的行为等于没生效）。这里用修复时记录的 SHA256 做漂移检测。
    private func dylibDriftMessage(bundleDylib: URL, expected: String) -> String? {
        guard !expected.isEmpty, expected != "unavailable" else { return nil }
        if let actual = sha256Hex(of: bundleDylib), actual == expected { return nil }

        // ad-hoc 签名不是确定性的：同一个 dylib 每次 codesign 出来的文件内容都不同，
        // 所以「文件哈希不一致」并不能证明运行时库过时。退回比较 Mach-O 的 UUID ——
        // 它由构建决定，签名前后完全一致。
        // Bundle.main 在 CLI 里没有 Resources，需要退回 FileSystemPaths 的候选路径。
        let shipped = FileSystemPaths.runtimeDylibCandidates.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
        if let bundled = shipped,
           let installed = machoUUIDs(of: bundleDylib),
           let shipped = machoUUIDs(of: bundled),
           !installed.isEmpty, installed == shipped {
            return nil
        }

        return "修复包内的 dylib 与修复记录不一致（Launcher 或运行时资源已更新），请重新修复。"
    }

    /// 读取 Mach-O 全部架构的 LC_UUID（universal 文件会有多个）。
    ///
    /// 直接解析文件头，不调 `/usr/bin/dwarfdump`：未安装 Xcode Command Line Tools
    /// 的机器上那个路径是 shim，一执行就弹「安装命令行开发者工具」对话框。
    private func machoUUIDs(of url: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.parseMachoUUIDs(data)
    }

    /// 支持 Fat/Universal（0xCAFEBABE / 0xCAFEBABF）与 64 位 / 32 位 Mach-O。
    static func parseMachoUUIDs(_ data: Data) -> Set<String>? {
        func readU32BE(_ off: Int) -> UInt32? {
            guard off >= 0, off + 4 <= data.count else { return nil }
            var v: UInt32 = 0
            for i in 0..<4 { v = (v << 8) | UInt32(data[data.startIndex + off + i]) }
            return v
        }
        func readU32LE(_ off: Int) -> UInt32? {
            guard off >= 0, off + 4 <= data.count else { return nil }
            var v: UInt32 = 0
            for i in (0..<4).reversed() { v = (v << 8) | UInt32(data[data.startIndex + off + i]) }
            return v
        }

        // 在 [base, base+size) 区间内解析单个 Mach-O slice 的 LC_UUID。
        func scanSlice(base: Int, size: Int, into out: inout Set<String>) {
            guard size >= 28, base + size <= data.count else { return }
            let magicLE = readU32LE(base) ?? 0
            let magicBE = readU32BE(base) ?? 0

            let is64: Bool
            let littleEndian: Bool
            switch (magicLE, magicBE) {
            case (0xfeedfacf, _): is64 = true;  littleEndian = true
            case (0xfeedface, _): is64 = false; littleEndian = true
            case (_, 0xfeedfacf): is64 = true;  littleEndian = false
            case (_, 0xfeedface): is64 = false; littleEndian = false
            default: return
            }

            let read = littleEndian ? readU32LE : readU32BE
            let ncmds = read(base + 16) ?? 0
            var cursor = base + (is64 ? 32 : 28)
            let sliceEnd = base + size

            for _ in 0..<Int(ncmds) {
                guard let cmd = read(cursor),
                      let cmdsize = read(cursor + 4),
                      cmdsize >= 8, cursor + Int(cmdsize) <= sliceEnd
                else { return }

                if cmd == 0x1b, cmdsize == 24 {   // LC_UUID
                    var hex = ""
                    for i in 0..<16 { hex += String(format: "%02X", data[data.startIndex + cursor + 8 + i]) }
                    let p1 = String(hex.prefix(8))
                    let p2 = String(hex.dropFirst(8).prefix(4))
                    let p3 = String(hex.dropFirst(12).prefix(4))
                    let p4 = String(hex.dropFirst(16).prefix(4))
                    let p5 = String(hex.dropFirst(20).prefix(12))
                    out.insert("\(p1)-\(p2)-\(p3)-\(p4)-\(p5)")
                }
                cursor += Int(cmdsize)
            }
        }

        var uuids = Set<String>()
        let magicBE = readU32BE(0) ?? 0

        if magicBE == 0xcafebabe || magicBE == 0xcafebabf {
            let is64Fat = magicBE == 0xcafebabf
            guard let nfat = readU32BE(4) else { return nil }
            var entry = 8
            for _ in 0..<Int(nfat) {
                guard entry + (is64Fat ? 32 : 20) <= data.count else { break }
                // fat_arch: cputype(4) cpusubtype(4) offset(4|8) size(4|8) align(4)
                let offset: UInt32? = is64Fat ? readU32BE(entry + 12) : readU32BE(entry + 8)
                let size: UInt32? = is64Fat ? readU32BE(entry + 20) : readU32BE(entry + 12)
                if let o = offset, let z = size, z > 0 {
                    scanSlice(base: Int(o), size: Int(z), into: &uuids)
                }
                entry += is64Fat ? 32 : 20
            }
        } else {
            scanSlice(base: 0, size: data.count, into: &uuids)
        }

        return uuids.isEmpty ? nil : uuids
    }

    private func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The generated wrapper is a shell script that installs the injected dylib.
    private func isProxyWrapper(at url: URL) -> Bool {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return contents.contains("libAntigravityTun.dylib")
            && contents.contains("DYLD_INSERT_LIBRARIES")
    }

    /// `disable-library-validation` is what lets DYLD_INSERT_LIBRARIES load our
    /// unsigned dylib into the (hardened runtime) CLI binary.
    private func binaryHasInjectionEntitlement(at url: URL) -> Bool {
        guard let result = try? CommandRunner.run(
            "/usr/bin/codesign",
            ["-d", "--entitlements", "-", url.path]
        ) else {
            return false
        }
        return result.stdout.contains("disable-library-validation")
    }

    private func latestMetadata() -> PatchMetadata? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: FileSystemPaths.metadataRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates = files.filter {
            $0.lastPathComponent.hasPrefix("launcher_patch_metadata_") && $0.pathExtension == "json"
        }

        let decoder = JSONDecoder()
        var latest: PatchMetadata?

        for url in candidates {
            guard
                let data = try? Data(contentsOf: url),
                let current = try? decoder.decode(PatchMetadata.self, from: data)
            else {
                continue
            }

            if let existed = latest {
                if current.patchedAt > existed.patchedAt {
                    latest = current
                }
            } else {
                latest = current
            }
        }

        return latest
    }
}
