import Foundation

enum LauncherCLICommand: Equatable {
    case doctor
    case verifyPatched
    case verifyAll
    case restartGateway
    case patchAndLaunch
    case help
    case unknown(String)
    case none
}

enum LauncherCLICommandParser {
    static func parse(from args: [String]) -> LauncherCLICommand {
        let cliArgs = Array(args.dropFirst())

        for arg in cliArgs {
            if arg == "--" {
                continue
            }

            switch arg {
            case "--doctor": return .doctor
            case "--verify-patched": return .verifyPatched
            case "--verify-all": return .verifyAll
            case "--restart-gateway": return .restartGateway
            case "--patch-and-launch": return .patchAndLaunch
            case "--help", "-h": return .help
            default:
                if arg.hasPrefix("--") || arg == "-h" {
                    return .unknown(arg)
                }
            }
        }

        return .none
    }

    static var helpText: String {
        let executableName = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "AntigravityProxyLauncher"

        return """
Usage:
    \(executableName) --doctor
    \(executableName) --export-diagnostics
    \(executableName) --verify-patched
    \(executableName) --verify-all      # 逐个目标检查 Antigravity / IDE / Gemini / agy
    \(executableName) --restart-gateway # 按最新配置重启本地网关（18081）
    \(executableName) --patch-and-launch
    \(executableName) --help

Legacy SwiftPM mode:
    # 非 .app 进程不要无参数启动（缺少 .app bundle 元数据）
  swift run AntigravityProxyLauncher -- --doctor
  swift run AntigravityProxyLauncher -- --export-diagnostics
  swift run AntigravityProxyLauncher -- --verify-patched
  swift run AntigravityProxyLauncher -- --verify-all
  swift run AntigravityProxyLauncher -- --restart-gateway
  swift run AntigravityProxyLauncher -- --patch-and-launch
  swift run AntigravityProxyLauncher -- --help

GUI mode (.app):
    open /path/to/AntigravityProxyLauncher.app
"""
    }
}