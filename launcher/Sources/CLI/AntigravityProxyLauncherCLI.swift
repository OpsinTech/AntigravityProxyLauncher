import Foundation
import Darwin

@main
struct AntigravityProxyLauncherCLI {
    static func main() {
        do {
            try FileSystemPaths.ensureRuntimeDirectoriesExist()
        } catch {
            LauncherLogger.warn("Failed to ensure runtime directories: \(error.localizedDescription)")
        }

        let doctor = LauncherDoctor()

        switch LauncherCLICommandParser.parse(from: CommandLine.arguments) {
        case .doctor:
            Darwin.exit(doctor.run())
        case .verifyPatched:
            Darwin.exit(doctor.verifyPatchedAppFromCLI())
        case .patchAndLaunch:
            Darwin.exit(doctor.patchAndLaunchFromCLI())
        case .help:
            print(LauncherCLICommandParser.helpText)
            Darwin.exit(0)
        case .unknown(let arg):
            print("未知参数: \(arg)")
            print(LauncherCLICommandParser.helpText)
            Darwin.exit(2)
        case .none:
            print(LauncherCLICommandParser.helpText)
            Darwin.exit(0)
        }
    }
}
