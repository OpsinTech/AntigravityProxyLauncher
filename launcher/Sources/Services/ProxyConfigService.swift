import Foundation

enum ProxyConfigServiceError: Error {
    case invalidPort(Int)
}

struct ProxyConfigSaveResult {
    let userConfigPath: String
    let patchedConfigSynced: Bool
}

extension ProxyConfigServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "代理端口不合法: \(port)，应在 1-65535 之间"
        }
    }
}

struct ProxyConfigService {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func loadForEditor() throws -> ProxyConfig {
        if FileManager.default.fileExists(atPath: FileSystemPaths.userProxyConfigFile.path) {
            return try load(from: FileSystemPaths.userProxyConfigFile)
        }

        if FileSystemPaths.activeApp.targetType == .cliBinary {
            if FileManager.default.fileExists(atPath: FileSystemPaths.patchedCLIConfig.path) {
                return try load(from: FileSystemPaths.patchedCLIConfig)
            }
        } else {
            let patchedConfig = FileSystemPaths.patchedApp
                .appendingPathComponent("Contents/Resources/proxy_config.json")
            if FileManager.default.fileExists(atPath: patchedConfig.path) {
                return try load(from: patchedConfig)
            }
        }

        if FileManager.default.fileExists(atPath: FileSystemPaths.bundledProxyConfigTemplate.path) {
            return try load(from: FileSystemPaths.bundledProxyConfigTemplate)
        }

        return .default
    }

    func saveForNextPatch(_ config: ProxyConfig) throws -> ProxyConfigSaveResult {
        guard (1...65535).contains(config.proxy.port) else {
            throw ProxyConfigServiceError.invalidPort(config.proxy.port)
        }

        try FileManager.default.createDirectory(
            at: FileSystemPaths.userConfigRoot,
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(config)
        try data.write(to: FileSystemPaths.userProxyConfigFile)

        var synced = false
        let patchedConfig: URL
        if FileSystemPaths.activeApp.targetType == .cliBinary {
            patchedConfig = FileSystemPaths.patchedCLIConfig
        } else {
            patchedConfig = FileSystemPaths.patchedApp
                .appendingPathComponent("Contents/Resources/proxy_config.json")
        }
        if FileManager.default.fileExists(atPath: patchedConfig.path) {
            try data.write(to: patchedConfig)
            synced = true
        }

        return ProxyConfigSaveResult(
            userConfigPath: FileSystemPaths.userProxyConfigFile.path,
            patchedConfigSynced: synced
        )
    }

    private func load(from url: URL) throws -> ProxyConfig {
        let data = try Data(contentsOf: url)
        return try decoder.decode(ProxyConfig.self, from: data)
    }
}
