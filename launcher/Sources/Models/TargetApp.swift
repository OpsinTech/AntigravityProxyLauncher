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
    case claudeCode
    case codex

    var id: String { self.rawValue }

    var targetType: TargetType {
        switch self {
        case .antigravity, .antigravityIDE, .gemini: return .appBundle
        case .agy, .claudeCode, .codex: return .cliBinary
        }
    }

    var ideType: String {
        switch self {
        case .antigravity: return "ANTIGRAVITY"
        case .antigravityIDE: return "ANTIGRAVITY_IDE"
        case .gemini: return "GEMINI"
        case .agy: return "CLI"
        case .claudeCode: return "CLAUDE_CODE"
        case .codex: return "CODEX"
        }
    }

    /// Source type for model routing categorization.
    /// - "google": Google-ecosystem apps (Antigravity, Antigravity IDE, Gemini, Agy)
    /// - "anthropic": Claude Code (Anthropic ecosystem)
    /// - nil: not yet supported (Codex)
    var sourceType: String? {
        switch self {
        case .claudeCode: return "anthropic"
        case .codex: return nil
        case .gemini, .antigravity, .antigravityIDE, .agy: return "google"
        }
    }

    var iconName: String {
        switch self {
        case .antigravity: return "gauge.with.needle"
        case .antigravityIDE: return "macwindow.badge.plus"
        case .gemini: return "sparkles"
        case .agy: return "terminal.fill"
        case .claudeCode: return "hammer.fill"
        case .codex: return "cube.fill"
        }
    }

    var displayName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .antigravityIDE: return "Antigravity IDE"
        case .gemini: return "Gemini"
        case .agy: return "Agy CLI"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .antigravity: return "com.google.antigravity"
        case .antigravityIDE: return "com.google.antigravity-ide"
        case .gemini: return "com.google.GeminiMacOS"
        case .agy, .claudeCode, .codex: return ""
        }
    }

    var defaultPath: String {
        switch self {
        case .antigravity: return "/Applications/Antigravity.app"
        case .antigravityIDE: return "/Applications/Antigravity IDE.app"
        case .gemini: return "/Applications/Gemini.app"
        case .agy: return "~/.local/bin/agy"
        case .claudeCode: return "~/.local/bin/claude"
        case .codex: return "~/.local/bin/codex"
        }
    }

    var patchedName: String {
        switch self {
        case .antigravity: return "Antigravity_Unlocked.app"
        case .antigravityIDE: return "Antigravity IDE_Unlocked.app"
        case .gemini: return "Gemini_Unlocked.app"
        case .agy: return "agy"
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    var launchArguments: [String] {
        switch self {
        case .antigravity, .antigravityIDE, .gemini:
            return ["--use-mock-keychain", "--password-store=basic"]
        case .agy, .claudeCode, .codex:
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
        case .gemini, .agy, .claudeCode, .codex:
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
        case .claudeCode: return "claude"
        case .codex: return "codex"
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
        case .gemini, .agy, .claudeCode, .codex:
            return []
        }
    }

    // MARK: - App categorization

    /// All apps that are App Bundles (GUI apps)
    static var allAppBundles: [TargetApp] {
        allCases.filter { $0.targetType == .appBundle }
    }

    /// All apps that are CLI binaries
    static var allCLIApps: [TargetApp] {
        allCases.filter { $0.targetType == .cliBinary }
    }

    /// Apps that are currently supported (not coming soon)
    static var supportedApps: [TargetApp] {
        allCases.filter { $0.sourceType != nil }
    }

    // MARK: - CLI-specific properties

    /// Arguments to pass to the CLI binary to get its version string
    var cliVersionArgs: [String] {
        switch self {
        case .agy, .claudeCode, .codex: return ["--version"]
        default: return []
        }
    }

    /// The real binary name inside the patched CLI directory
    var cliRealBinaryName: String {
        switch self {
        case .agy: return "agy-real"
        case .claudeCode: return "claude-real"
        case .codex: return "codex-real"
        default: return ""
        }
    }

    /// Relative path from home to the patched CLI directory
    var cliPatchedDirRelativePath: String {
        switch self {
        case .agy: return ".antigravity/antigravity/bin"
        case .claudeCode: return ".antigravity/claude/bin"
        case .codex: return ".antigravity/codex/bin"
        default: return ""
        }
    }
}
