import Foundation

/// Service for loading and saving model routing configuration.
/// Single config file: ~/.config/antigravity/model_routing.json
struct ModelRoutingService {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func configPath() -> String {
        FileSystemPaths.userModelRoutingConfigFile.path
    }

    func load() throws -> ModelRoutingConfig {
        let url = FileSystemPaths.userModelRoutingConfigFile
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                return try loadFrom(url: url)
            } catch {
                // Config corrupted — backup and use defaults
                let brokenPath = url.path
                let backupPath = brokenPath + ".corrupted." + ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                try? FileManager.default.copyItem(atPath: brokenPath, toPath: backupPath)
                try? FileManager.default.removeItem(atPath: brokenPath)
                let config = ModelRoutingConfig.default
                try save(config)
                return config
            }
        }
        // First launch: use defaults and save
        let config = ModelRoutingConfig.default
        try save(config)
        return config
    }

    func save(_ config: ModelRoutingConfig) throws {
        let url = FileSystemPaths.userModelRoutingConfigFile
        try saveTo(url: url, config: config)
    }

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
