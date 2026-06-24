import Foundation

/// Service for loading, saving, and managing the model routing configuration
/// stored at `~/.config/antigravity/model_routing.json`.
struct ModelRoutingService {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Returns the absolute path to the model routing configuration file.
    func configPath() -> String {
        FileSystemPaths.userModelRoutingConfigFile.path
    }

    /// Loads the model routing configuration from disk.
    /// On first launch (no file), writes the default config so the Go proxy
    /// can pick it up immediately without requiring manual UI save.
    /// On subsequent loads, merges any new default providers not yet in the saved config.
    func load() throws -> ModelRoutingConfig {
        let url = FileSystemPaths.userModelRoutingConfigFile

        guard FileManager.default.fileExists(atPath: url.path) else {
            // First launch: persist default config so Go proxy finds it
            try save(.default)
            return .default
        }

        let data = try Data(contentsOf: url)
        var config = try decoder.decode(ModelRoutingConfig.self, from: data)

        // Merge new default providers that don't exist in the saved config yet
        let existingIDs = Set(config.providers.map(\.id))
        for defaultProvider in ModelRoutingConfig.default.providers {
            if !existingIDs.contains(defaultProvider.id) {
                config.providers.append(defaultProvider)
            }
        }

        return config
    }

    /// Persists the given model routing configuration to disk.
    func save(_ config: ModelRoutingConfig) throws {
        let url = FileSystemPaths.userModelRoutingConfigFile

        // Ensure the parent directory exists
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }
}
