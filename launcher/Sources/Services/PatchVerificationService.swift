import Foundation

struct CodeSignVerifyFailureDetail {
    let command: String
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum PatchVerificationError: LocalizedError {
    case patchedAppMissing(String)
    case infoPlistMissing(String)
    case executableMissing(String)
    case dylibMissing(String)
    case configMissing(String)
    case invalidLSEnvironment
    case invalidCLIWrapper(String)
    case codeSignVerifyFailed(CodeSignVerifyFailureDetail)

    var errorDescription: String? {
        switch self {
        case .patchedAppMissing(let path):
            return "验证失败: patched app 不存在 -> \(path)"
        case .infoPlistMissing(let path):
            return "验证失败: Info.plist 不存在 -> \(path)"
        case .executableMissing(let path):
            return "验证失败: 主执行文件不存在 -> \(path)"
        case .dylibMissing(let path):
            return "验证失败: dylib 不存在 -> \(path)"
        case .configMissing(let path):
            return "验证失败: 配置文件不存在 -> \(path)"
        case .invalidLSEnvironment:
            return "验证失败: LSEnvironment 缺失或内容不正确"
        case .invalidCLIWrapper(let path):
            return "验证失败: CLI wrapper 脚本无效 -> \(path)"
        case .codeSignVerifyFailed(let detail):
            let stdout = detail.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = detail.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "验证失败: codesign --verify 未通过\ncommand: \(detail.command)\nexit: \(detail.exitCode)\nstdout: \(stdout)\nstderr: \(stderr)"
        }
    }
}

struct PatchVerificationService {
    func verifyPatchedResult() throws {
        if FileSystemPaths.activeApp.targetType == .cliBinary {
            try verifyPatchedCLI()
            return
        }

        let appURL = FileSystemPaths.patchedApp
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")

        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw PatchVerificationError.patchedAppMissing(appURL.path)
        }

        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            throw PatchVerificationError.infoPlistMissing(infoURL.path)
        }

        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw PatchVerificationError.invalidLSEnvironment
        }

        let executableName = info["CFBundleExecutable"] as? String ?? "Electron"
        let executablePath = appURL
            .appendingPathComponent("Contents/MacOS/\(executableName)")
            .path

        let dylibPath = appURL
            .appendingPathComponent("Contents/Resources/libAntigravityTun.dylib")
            .path

        guard FileManager.default.fileExists(atPath: executablePath) else {
            throw PatchVerificationError.executableMissing(executablePath)
        }

        guard FileManager.default.fileExists(atPath: dylibPath) else {
            throw PatchVerificationError.dylibMissing(dylibPath)
        }

        let expectedConfigPath = FileSystemPaths.userProxyConfigFile.path

        guard let lsEnvironment = info["LSEnvironment"] as? [String: String],
              let injected = lsEnvironment["DYLD_INSERT_LIBRARIES"],
              lsEnvironment["ANTIGRAVITY_CONFIG"] == expectedConfigPath else {
            throw PatchVerificationError.invalidLSEnvironment
        }

        // 注入必须是绝对路径且文件真实存在。`@executable_path/../Resources/...` 这种
        // 相对写法会让 helper 进程（Helper.app、bin/language_server）解析到
        // .../xxx.app/Contents/Resources/Resources/... 然后 dyld abort。
        if !injected.hasPrefix("/") || !FileManager.default.fileExists(atPath: injected) {
            throw PatchVerificationError.invalidLSEnvironment
        }

        let helperFrameworks = appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let helperApps = (try? FileManager.default.contentsOfDirectory(
            at: helperFrameworks,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "app" && $0.lastPathComponent.contains("Helper") } ?? []

        // helper 各自是否带 dylib 副本不再作为判据：注入走的是主机绝对路径，
        // helper 通过 DYLD_INSERT_LIBRARIES 继承即可，无需本地副本。
        _ = helperApps

        let args = ["--verify", "--deep", "--strict", "--verbose=4", appURL.path]
        let commandText = "/usr/bin/codesign " + args.joined(separator: " ")

        do {
            _ = try CommandRunner.run("/usr/bin/codesign", args)
        } catch let commandError as CommandRunnerError {
            switch commandError {
            case .nonZeroExit(let result):
                throw PatchVerificationError.codeSignVerifyFailed(
                    .init(
                        command: commandText,
                        exitCode: result.status,
                        stdout: result.stdout,
                        stderr: result.stderr
                    )
                )
            case .executableNotFound, .commandFailed:
                throw PatchVerificationError.codeSignVerifyFailed(
                    .init(
                        command: commandText,
                        exitCode: -1,
                        stdout: "",
                        stderr: commandError.localizedDescription
                    )
                )
            }
        } catch {
            throw PatchVerificationError.codeSignVerifyFailed(
                .init(
                    command: commandText,
                    exitCode: -1,
                    stdout: "",
                    stderr: error.localizedDescription
                )
            )
        }
    }

    private func verifyPatchedCLI() throws {
        let wrapper = FileSystemPaths.patchedCLIWrapper
        let realBinary = FileSystemPaths.patchedCLIRealBinary
        let dylib = FileSystemPaths.patchedCLIDylib
        let fm = FileManager.default

        guard fm.fileExists(atPath: wrapper.path) else {
            throw PatchVerificationError.patchedAppMissing(wrapper.path)
        }
        guard fm.fileExists(atPath: realBinary.path) else {
            throw PatchVerificationError.executableMissing(realBinary.path)
        }
        guard fm.fileExists(atPath: dylib.path) else {
            throw PatchVerificationError.dylibMissing(dylib.path)
        }
        // Verify wrapper script contains required env vars
        guard let content = try? String(contentsOf: wrapper, encoding: .utf8),
              content.contains("DYLD_INSERT_LIBRARIES"),
              content.contains("ANTIGRAVITY_CONFIG") else {
            throw PatchVerificationError.invalidCLIWrapper(wrapper.path)
        }

        // Verify code signature on the real binary
        let args = ["--verify", "--strict", "--verbose=4", realBinary.path]
        let commandText = "/usr/bin/codesign " + args.joined(separator: " ")
        do {
            _ = try CommandRunner.run("/usr/bin/codesign", args)
        } catch let commandError as CommandRunnerError {
            switch commandError {
            case .nonZeroExit(let result):
                throw PatchVerificationError.codeSignVerifyFailed(
                    .init(
                        command: commandText,
                        exitCode: result.status,
                        stdout: result.stdout,
                        stderr: result.stderr
                    )
                )
            case .executableNotFound, .commandFailed:
                throw PatchVerificationError.codeSignVerifyFailed(
                    .init(
                        command: commandText,
                        exitCode: -1,
                        stdout: "",
                        stderr: commandError.localizedDescription
                    )
                )
            }
        } catch {
            throw PatchVerificationError.codeSignVerifyFailed(
                .init(
                    command: commandText,
                    exitCode: -1,
                    stdout: "",
                    stderr: error.localizedDescription
                )
            )
        }
    }
}
