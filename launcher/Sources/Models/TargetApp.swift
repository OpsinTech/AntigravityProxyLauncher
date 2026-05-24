import Foundation

enum TargetApp: String, Codable, CaseIterable, Identifiable {
    case antigravity
    case antigravityIDE
    case gemini

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .antigravityIDE: return "Antigravity IDE"
        case .gemini: return "Gemini"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .antigravity: return "com.google.antigravity"
        case .antigravityIDE: return "com.google.antigravity-ide"
        case .gemini: return "com.google.GeminiMacOS"
        }
    }

    var defaultPath: String {
        switch self {
        case .antigravity: return "/Applications/Antigravity.app"
        case .antigravityIDE: return "/Applications/Antigravity IDE.app"
        case .gemini: return "/Applications/Gemini.app"
        }
    }

    var patchedName: String {
        switch self {
        case .antigravity: return "Antigravity_Unlocked.app"
        case .antigravityIDE: return "Antigravity IDE_Unlocked.app"
        case .gemini: return "Gemini_Unlocked.app"
        }
    }

    var launchArguments: [String] {
        switch self {
        case .antigravity, .antigravityIDE:
            return ["--use-mock-keychain", "--password-store=basic"]
        case .gemini:
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
        case .gemini:
            return [:]
        }
    }

    /// The executable name inside Contents/MacOS/
    var executableName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .antigravityIDE: return "Electron"
        case .gemini: return "Gemini"
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
        case .gemini:
            return []
        }
    }
}
