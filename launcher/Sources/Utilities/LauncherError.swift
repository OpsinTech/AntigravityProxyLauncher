import Foundation

enum LauncherErrorCode: Int32 {
    case success = 0

    case targetAppMissing = 1001
    case unsupportedVersion = 1002

    case patchFailed = 1101
    case runtimeAssetMissing = 1102
    case rollbackFailed = 1103

    case migrationFailed = 1201
    case launchFailed = 1301

    case verifyFailed = 1401
    case codeSignVerifyFailed = 1402

    case diagnosticsExportFailed = 1501

    case commandExecutionFailed = 1901
    case unknown = 1999
}

struct LauncherFailure {
    static let domain = "com.antigravity.launcher"

    let code: LauncherErrorCode
    let message: String

    var codeValue: Int32 {
        code.rawValue
    }

    var formatted: String {
        "[\(Self.domain):\(code.rawValue)] \(message)"
    }
}

enum LauncherErrorMapper {
    static func map(_ error: Error) -> LauncherFailure {
        if let patch = error as? PatchServiceError {
            switch patch {
            case .targetAppMissing:
                return .init(code: .targetAppMissing, message: patch.localizedDescription)
            case .runtimeAssetMissing:
                return .init(code: .runtimeAssetMissing, message: patch.localizedDescription)
            case .rollbackFailed:
                return .init(code: .rollbackFailed, message: patch.localizedDescription)
            default:
                return .init(code: .patchFailed, message: patch.localizedDescription)
            }
        }

        if let verification = error as? PatchVerificationError {
            switch verification {
            case .codeSignVerifyFailed(_):
                return .init(code: .codeSignVerifyFailed, message: verification.localizedDescription)
            default:
                return .init(code: .verifyFailed, message: verification.localizedDescription)
            }
        }


        if let command = error as? CommandRunnerError {
            return .init(code: .commandExecutionFailed, message: String(describing: command))
        }

        return .init(code: .unknown, message: error.localizedDescription)
    }
}
