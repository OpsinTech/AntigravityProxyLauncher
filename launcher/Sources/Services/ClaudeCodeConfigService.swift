import Foundation

/// Service for configuring Claude Code to route API requests through the local Go MITM proxy.
/// Uses ANTHROPIC_BASE_URL instead of dylib injection — no patching required.
struct ClaudeCodeConfigService {
    private let settingsURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }()

    /// Reads current Claude Code settings. Returns nil if file doesn't exist.
    func loadSettings() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// Enables proxy mode: sets ANTHROPIC_BASE_URL to local Go proxy.
    /// Preserves all other settings. Returns true on success.
    func enableProxyMode(proxyHost: String = "127.0.0.1", proxyPort: Int = 18081) -> Bool {
        var settings = loadSettings() ?? [:]
        var env = (settings["env"] as? [String: Any]) ?? [:]

        env["ANTHROPIC_BASE_URL"] = "http://\(proxyHost):\(proxyPort)"
        // Remove provider-specific keys so they don't override the proxy
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        // Preserve model preferences
        settings["env"] = env

        return writeSettings(settings)
    }

    /// Disables proxy mode: removes ANTHROPIC_BASE_URL from settings.
    /// Preserves all other settings.
    func disableProxyMode() -> Bool {
        guard var settings = loadSettings(),
              var env = settings["env"] as? [String: Any] else {
            return true // Already clean
        }

        env.removeValue(forKey: "ANTHROPIC_BASE_URL")
        settings["env"] = env.isEmpty ? nil : env
        if env.isEmpty { settings.removeValue(forKey: "env") }

        return writeSettings(settings)
    }

    /// Checks if proxy mode is currently enabled
    func isProxyEnabled() -> Bool {
        guard let settings = loadSettings(),
              let env = settings["env"] as? [String: Any] else {
            return false
        }
        return env["ANTHROPIC_BASE_URL"] != nil
    }

    /// Get current proxy URL if enabled
    func currentProxyURL() -> String? {
        guard let settings = loadSettings(),
              let env = settings["env"] as? [String: Any] else {
            return nil
        }
        return env["ANTHROPIC_BASE_URL"] as? String
    }

    // MARK: - Private

    private func writeSettings(_ settings: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }

        // Backup existing settings first
        let backupURL = settingsURL.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        }

        // Atomic write
        let tempURL = settingsURL.appendingPathExtension("tmp")
        do {
            let parent = settingsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: tempURL, options: .atomic)
            try FileManager.default.replaceItemAt(settingsURL, withItemAt: tempURL, backupItemName: nil, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }
}
