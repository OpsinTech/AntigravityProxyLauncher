import Foundation

enum TargetType {
    case appBundle
    case cliBinary
}

enum TargetApp: String, Codable, CaseIterable, Identifiable {
    case antigravity
    case antigravityIDE
    case gemini
    case agy

    var id: String { self.rawValue }

    var targetType: TargetType {
        switch self {
        case .antigravity, .antigravityIDE, .gemini: return .appBundle
        case .agy: return .cliBinary
        }
    }

    var ideType: String {
        switch self {
        case .antigravity: return "ANTIGRAVITY"
        case .antigravityIDE: return "ANTIGRAVITY_IDE"
        case .gemini: return "GEMINI"
        case .agy: return "CLI"
        }
    }

    var iconName: String {
        switch self {
        case .antigravity: return "gauge.with.needle"
        case .antigravityIDE: return "macwindow.badge.plus"
        case .gemini: return "sparkles"
        case .agy: return "terminal.fill"
        }
    }

    var displayName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .antigravityIDE: return "Antigravity IDE"
        case .gemini: return "Gemini"
        case .agy: return "Agy CLI"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .antigravity: return "com.google.antigravity"
        case .antigravityIDE: return "com.google.antigravity-ide"
        case .gemini: return "com.google.GeminiMacOS"
        case .agy: return ""
        }
    }

    var defaultPath: String {
        switch self {
        case .antigravity: return "/Applications/Antigravity.app"
        case .antigravityIDE: return "/Applications/Antigravity IDE.app"
        case .gemini: return "/Applications/Gemini.app"
        case .agy: return "~/.local/bin/agy"
        }
    }

    var patchedName: String {
        switch self {
        case .antigravity: return "Antigravity_Unlocked.app"
        case .antigravityIDE: return "Antigravity IDE_Unlocked.app"
        case .gemini: return "Gemini_Unlocked.app"
        case .agy: return "agy"
        }
    }

    var launchArguments: [String] {
        switch self {
        case .antigravity, .antigravityIDE, .gemini:
            return ["--use-mock-keychain", "--password-store=basic"]
        case .agy:
            return []
        }
    }

    var environmentVariables: [String: String] {
        switch self {
        case .antigravity, .antigravityIDE:
            return [
                "ELECTRON_NO_UPDATER": "1",
                "SUDisableAutomaticChecks": "YES"
            ]
        case .gemini, .agy:
            return [:]
        }
    }

    /// The executable name inside Contents/MacOS/
    var executableName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .antigravityIDE: return "Electron"
        case .gemini: return "Gemini"
        case .agy: return "agy"
        }
    }

    /// Helper bundle IDs that need to be terminated when stopping the app
    var helperBundleIdentifiers: [String] {
        switch self {
        case .antigravity:
            return [
                "com.google.antigravity.helper",
                "com.google.antigravity.helper.GPU",
                "com.google.antigravity.helper.Plugin",
                "com.google.antigravity.helper.Renderer"
            ]
        case .antigravityIDE:
            return [
                "com.google.antigravity-ide.helper"
            ]
        case .gemini, .agy:
            return []
        }
    }

    // MARK: - CLI-specific properties

    /// Arguments to pass to the CLI binary to get its version string
    var cliVersionArgs: [String] {
        switch self {
        case .agy: return ["--version"]
        default: return []
        }
    }

    /// The real binary name inside the patched CLI directory
    var cliRealBinaryName: String {
        switch self {
        case .agy: return "agy-real"
        default: return ""
        }
    }

    /// Relative path from home to the patched CLI directory
    var cliPatchedDirRelativePath: String {
        switch self {
        case .agy: return ".antigravity/antigravity/bin"
        default: return ""
        }
    }
}
