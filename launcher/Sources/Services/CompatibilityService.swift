import Foundation
import CryptoKit

enum CompatibilityError: Error {
    case registryMissing
    case decodeFailed
    case invalidRemoteURL
    case remoteDownloadFailed(String)
    case untrustedSource(String)
    case checksumMismatch
}

extension CompatibilityError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .registryMissing:
            return "未找到兼容规则文件"
        case .decodeFailed:
            return "兼容规则解析失败"
        case .invalidRemoteURL:
            return "兼容规则地址无效，仅支持 http/https"
        case .remoteDownloadFailed(let reason):
            return "兼容规则下载失败: \(reason)"
        case .untrustedSource(let host):
            return "规则来源不可信: \(host)"
        case .checksumMismatch:
            return "规则文件 SHA256 校验失败"
        }
    }
}

struct CompatibilityService {
    func loadRegistry() throws -> CompatibilityRegistry {
        try loadActiveRegistry().registry
    }

    func loadActiveRegistry() throws -> (registry: CompatibilityRegistry, source: String) {
        let fm = FileManager.default

        if fm.fileExists(atPath: FileSystemPaths.compatibilityRegistryCacheFile.path) {
            do {
                let data = try Data(contentsOf: FileSystemPaths.compatibilityRegistryCacheFile)
                let registry = try JSONDecoder().decode(CompatibilityRegistry.self, from: data)
                return (registry, "本地缓存规则")
            } catch {
                quarantineBrokenCacheIfNeeded()
                let bundled = try loadBundledRegistry()
                return (bundled, "内置规则（缓存损坏已回退）")
            }
        }

        return (try loadBundledRegistry(), "内置规则")
    }

    private func quarantineBrokenCacheIfNeeded() {
        let fm = FileManager.default
        let cacheURL = FileSystemPaths.compatibilityRegistryCacheFile
        guard fm.fileExists(atPath: cacheURL.path) else {
            return
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let brokenURL = cacheURL.deletingLastPathComponent()
            .appendingPathComponent("compatibility.registry.broken.\(stamp).json")

        try? fm.moveItem(at: cacheURL, to: brokenURL)
        try? fm.removeItem(at: FileSystemPaths.compatibilityRegistryCacheMetaFile)
    }

    func refreshRegistryFromRemote(
        urlString: String,
        trustedHostPatterns: [String],
        expectedSHA256: String?
    ) async throws -> CompatibilityRegistry {
        guard let url = URL(string: urlString), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw CompatibilityError.invalidRemoteURL
        }

        let host = (url.host ?? "").lowercased()
        if !trustedHostPatterns.isEmpty {
            let matched = trustedHostPatterns.contains { pattern in
                let normalized = pattern.lowercased()
                return host == normalized || host.hasSuffix("." + normalized)
            }
            if !matched {
                throw CompatibilityError.untrustedSource(host)
            }
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CompatibilityError.remoteDownloadFailed("HTTP \(http.statusCode)")
        }

        if let expected = expectedSHA256?.lowercased(), !expected.isEmpty {
            let digest = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            if digest != expected {
                throw CompatibilityError.checksumMismatch
            }
        }

        let registry: CompatibilityRegistry
        do {
            registry = try JSONDecoder().decode(CompatibilityRegistry.self, from: data)
        } catch {
            throw CompatibilityError.decodeFailed
        }

        try FileManager.default.createDirectory(at: FileSystemPaths.appSupportRoot, withIntermediateDirectories: true)
        try data.write(to: FileSystemPaths.compatibilityRegistryCacheFile)

        let meta = CompatibilityRegistryCacheMetadata(
            updatedAt: Date(),
            sourceURL: urlString,
            schemaVersion: registry.schemaVersion,
            ruleCount: registry.rules.count
        )
        let metaData = try JSONEncoder.pretty.encode(meta)
        try metaData.write(to: FileSystemPaths.compatibilityRegistryCacheMetaFile)

        return registry
    }

    func readCacheMetadata() -> CompatibilityRegistryCacheMetadata? {
        guard FileManager.default.fileExists(atPath: FileSystemPaths.compatibilityRegistryCacheMetaFile.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: FileSystemPaths.compatibilityRegistryCacheMetaFile) else {
            return nil
        }
        return try? JSONDecoder().decode(CompatibilityRegistryCacheMetadata.self, from: data)
    }

    private func loadBundledRegistry() throws -> CompatibilityRegistry {
        guard let url = FileSystemPaths.bundledCompatibilityRegistry else {
            throw CompatibilityError.registryMissing
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CompatibilityRegistry.self, from: data)
        } catch {
            throw CompatibilityError.decodeFailed
        }
    }

    func matchedRule(for app: AppInfo, registry: CompatibilityRegistry) -> CompatibilityRule? {
        let identifier: String
        if FileSystemPaths.activeApp.targetType == .cliBinary {
            identifier = FileSystemPaths.activeApp.rawValue
        } else {
            identifier = app.bundleIdentifier
        }

        return registry.rules.first { rule in
            rule.bundleIdentifier == identifier
                && compareVersion(app.version, rule.minVersion) >= 0
                && compareVersion(app.version, rule.maxVersion) <= 0
        }
    }

    func isSupported(_ app: AppInfo, registry: CompatibilityRegistry) -> Bool {
        matchedRule(for: app, registry: registry) != nil
    }

    private func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        lhs.compare(rhs, options: .numeric).rawValue
    }
}

struct CompatibilityRegistryCacheMetadata: Codable, Equatable {
    let updatedAt: Date
    let sourceURL: String
    let schemaVersion: Int
    let ruleCount: Int
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
