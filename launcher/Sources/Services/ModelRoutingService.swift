import Foundation

/// Service for loading, saving, and managing model routing configurations.
///
/// Editing layer: two per-ecosystem config files
///   - `~/.config/antigravity/model_routing_google.json`
///   - `~/.config/antigravity/model_routing_anthropic.json`
///
/// Proxy consumption layer: a single merged file
///   - `~/.config/antigravity/model_routing.json`
///
/// The Go proxy reads only the merged file; the Swift launcher generates it
/// automatically whenever either ecosystem config is saved.
struct ModelRoutingService {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Returns the absolute path to the merged proxy config file.
    func configPath() -> String {
        FileSystemPaths.userModelRoutingConfigFile.path
    }

    /// Returns the absolute path for a specific ecosystem config file.
    func configPath(for system: String) -> String {
        switch system {
        case "google":
            return FileSystemPaths.userModelRoutingConfigGoogleFile.path
        case "anthropic":
            return FileSystemPaths.userModelRoutingConfigAnthropicFile.path
        default:
            return FileSystemPaths.userModelRoutingConfigFile.path
        }
    }

    // MARK: - Load

    /// Loads both ecosystem configs, migrating from the old single file if necessary.
    func loadBoth() throws -> (google: ModelRoutingConfig, anthropic: ModelRoutingConfig) {
        let googleURL = FileSystemPaths.userModelRoutingConfigGoogleFile
        let anthropicURL = FileSystemPaths.userModelRoutingConfigAnthropicFile
        let mergedURL = FileSystemPaths.userModelRoutingConfigFile

        let googleExists = FileManager.default.fileExists(atPath: googleURL.path)
        let anthropicExists = FileManager.default.fileExists(atPath: anthropicURL.path)

        if googleExists && anthropicExists {
            // Normal path: load both ecosystem files
            let googleConfig = try loadFrom(url: googleURL)
            let anthropicConfig = try loadFrom(url: anthropicURL)
            return (googleConfig, anthropicConfig)
        }

        // Migration path: split old merged file, or use defaults
        let googleConfig: ModelRoutingConfig
        let anthropicConfig: ModelRoutingConfig

        if FileManager.default.fileExists(atPath: mergedURL.path) {
            do {
                let merged = try loadFrom(url: mergedURL)
                googleConfig = ModelRoutingConfig(
                    providers: merged.providers,
                    routingRules: merged.rules(for: "google")
                )
                anthropicConfig = ModelRoutingConfig(
                    providers: merged.providers,
                    routingRules: merged.rules(for: "anthropic")
                )
            } catch {
                // Config corrupted — backup and use defaults
                let brokenPath = mergedURL.path
                let backupPath = brokenPath + ".corrupted." + ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                try? FileManager.default.copyItem(atPath: brokenPath, toPath: backupPath)
                try? FileManager.default.removeItem(atPath: brokenPath)
                googleConfig = .defaultGoogle
                anthropicConfig = .defaultAnthropic
            }
        } else {
            googleConfig = .defaultGoogle
            anthropicConfig = .defaultAnthropic
        }

        // Persist the split files and regenerate the merged file
        try saveTo(url: googleURL, config: googleConfig)
        try saveTo(url: anthropicURL, config: anthropicConfig)
        try mergeAndSaveProxyConfig(google: googleConfig, anthropic: anthropicConfig)

        return (googleConfig, anthropicConfig)
    }

    /// Loads a single ecosystem config.
    func load(for system: String) throws -> ModelRoutingConfig {
        let url = URL(fileURLWithPath: configPath(for: system))
        return try loadFrom(url: url)
    }

    // MARK: - Save

    /// Saves the given config for the specified ecosystem, then regenerates the
    /// merged proxy file by loading the other ecosystem's config and merging.
    func save(_ config: ModelRoutingConfig, for system: String) throws {
        let url = URL(fileURLWithPath: configPath(for: system))
        try saveTo(url: url, config: config)

        // Reload the other ecosystem and regenerate the merged proxy file
        let otherSystem = system == "google" ? "anthropic" : "google"
        let otherConfig: ModelRoutingConfig
        do {
            otherConfig = try load(for: otherSystem)
        } catch {
            otherConfig = (otherSystem == "google") ? .defaultGoogle : .defaultAnthropic
        }

        if system == "google" {
            try mergeAndSaveProxyConfig(google: config, anthropic: otherConfig)
        } else {
            try mergeAndSaveProxyConfig(google: otherConfig, anthropic: config)
        }
    }

    /// Merges google + anthropic configs and writes the combined result to the
    /// Go proxy's `model_routing.json`.
    func mergeAndSaveProxyConfig(google: ModelRoutingConfig, anthropic: ModelRoutingConfig) throws {
        let merged = google.mergeWith(anthropic)
        try saveTo(url: FileSystemPaths.userModelRoutingConfigFile, config: merged)
    }

    // MARK: - Private helpers

    private func loadFrom(url: URL) throws -> ModelRoutingConfig {
        let data = try Data(contentsOf: url)
        return try decoder.decode(ModelRoutingConfig.self, from: data)
    }

    private func saveTo(url: URL, config: ModelRoutingConfig) throws {
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }
}
