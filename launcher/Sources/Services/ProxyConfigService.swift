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
        // If global config exists, load it
        if FileManager.default.fileExists(atPath: FileSystemPaths.userProxyConfigFile.path) {
            do {
                return try load(from: FileSystemPaths.userProxyConfigFile)
            } catch {
                // Config file is corrupted — backup the broken file and regenerate defaults
                let brokenPath = FileSystemPaths.userProxyConfigFile.path
                let backupPath = brokenPath + ".corrupted." + ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                try? FileManager.default.copyItem(atPath: brokenPath, toPath: backupPath)
                try? FileManager.default.removeItem(atPath: brokenPath)
                LauncherLogger.warn("proxy_config.json 已损坏，已备份至 \(backupPath)，将使用默认配置")
            }
        }

        // First launch: try to migrate from old per-app paths (best-effort)
        let oldPaths: [URL] = {
            let saved = FileSystemPaths.activeApp
            defer { FileSystemPaths.activeApp = saved }
            var paths: [URL] = []
            for app in TargetApp.allCases {
                FileSystemPaths.activeApp = app
                let oldFile: URL
                switch app {
                case .agy, .claudeCode, .codex:
                    oldFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/antigravity/proxy_config.json")
                case .antigravity:
                    oldFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Antigravity/proxy_config.json")
                case .antigravityIDE:
                    oldFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Antigravity IDE/proxy_config.json")
                case .gemini:
                    oldFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AntigravityProxy/gemini/Config/proxy_config.json")
                }
                if FileManager.default.fileExists(atPath: oldFile.path), !paths.contains(oldFile) {
                    paths.append(oldFile)
                }
            }
            return paths
        }()

        if let oldPath = oldPaths.first,
           let config = try? load(from: oldPath) {
            _ = try? self.saveForNextPatch(config)
            return config
        }

        // Fallback: load from bundled template or default, then save
        let config: ProxyConfig
        let templatePath = FileSystemPaths.bundledProxyConfigTemplate
        if FileManager.default.fileExists(atPath: templatePath.path),
           let template = try? load(from: templatePath) {
            config = template
        } else {
            config = .default
        }
        _ = try self.saveForNextPatch(config)
        return config
    }

    func saveForNextPatch(_ config: ProxyConfig) throws -> ProxyConfigSaveResult {
        guard (1...65535).contains(config.proxy.port) else {
            throw ProxyConfigServiceError.invalidPort(config.proxy.port)
        }

        let dir = FileSystemPaths.userProxyConfigFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let data = try encoder.encode(config)
        try data.write(to: FileSystemPaths.userProxyConfigFile)

        return ProxyConfigSaveResult(
            userConfigPath: FileSystemPaths.userProxyConfigFile.path,
            patchedConfigSynced: true
        )
    }

    private func load(from url: URL) throws -> ProxyConfig {
        let data = try Data(contentsOf: url)
        return try decoder.decode(ProxyConfig.self, from: data)
    }
}
