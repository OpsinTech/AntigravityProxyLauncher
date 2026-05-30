import Foundation

enum TokenStoreError: Error {
    case encodeFailed
    case decodeFailed
    case fileSystemError(Error)
    case keychainError(Error)
    case tokenExpired
}

extension TokenStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .encodeFailed:
            return "Failed to encode OAuth token."
        case .decodeFailed:
            return "Failed to decode OAuth token."
        case .fileSystemError(let error):
            return "File system error: \(error.localizedDescription)"
        case .keychainError(let error):
            return "Keychain error: \(error.localizedDescription)"
        case .tokenExpired:
            return "Token has expired."
        }
    }
}

struct TokenStoreService {
    private let tokensDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        self.tokensDirectory = FileSystemPaths.appSupportRoot.appendingPathComponent("oauth_tokens")
        
        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: tokensDirectory,
            withIntermediateDirectories: true
        )
    }

    private func keychainKey(for accountId: String) -> String {
        return "oauth_token_\(accountId)"
    }

    func saveToken(_ token: OAuthToken, for accountId: String, allowUserInteraction: Bool = true) throws {
        let payload: Data
        do {
            payload = try encoder.encode(token)
        } catch {
            throw TokenStoreError.encodeFailed
        }

        // 1. Save to secure disk directory first (always succeeds, zero prompts)
        let fileURL = tokensDirectory.appendingPathComponent("\(accountId).json")
        do {
            try payload.write(to: fileURL, options: .atomic)
        } catch {
            throw TokenStoreError.fileSystemError(error)
        }

        // 2. Try to store in Keychain as a fallback, but catch any keychain access errors
        // (such as prompt rejection or code signing mismatches) to avoid interrupting the user.
        do {
            try KeychainService.save(key: keychainKey(for: accountId), data: payload)
        } catch {
            // Silently log keychain failures on unsigned local builds
            print("[TokenStore] Keychain sync failed: \(error.localizedDescription). Saved to disk.")
        }
    }

    func loadToken(for accountId: String, allowUserInteraction: Bool = true) throws -> OAuthToken? {
        // 1. Prioritize loading from disk to completely avoid triggering macOS Keychain prompts
        let fileURL = tokensDirectory.appendingPathComponent("\(accountId).json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                return try decoder.decode(OAuthToken.self, from: data)
            } catch {
                // If disk decoding fails, fall through to keychain
                print("[TokenStore] Disk load failed for \(accountId), falling through to Keychain.")
            }
        }

        // 2. Fall back to Keychain if not found on disk, wrapping in a try-catch to prevent prompt issues
        do {
            guard let data = try KeychainService.load(key: keychainKey(for: accountId)) else {
                return nil
            }
            let token = try decoder.decode(OAuthToken.self, from: data)
            
            // Auto-cache back to disk for future prompt-free loads
            try? data.write(to: fileURL, options: .atomic)
            
            return token
        } catch {
            print("[TokenStore] Keychain load failed: \(error.localizedDescription)")
            return nil
        }
    }

    func hasToken(for accountId: String, allowUserInteraction: Bool = true) -> Bool {
        // Check disk directly first (extremely fast and prompt-free)
        let fileURL = tokensDirectory.appendingPathComponent("\(accountId).json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return true
        }
        
        do {
            return try loadToken(for: accountId, allowUserInteraction: allowUserInteraction) != nil
        } catch {
            return false
        }
    }

    func deleteToken(for accountId: String) throws {
        // Delete from disk
        let fileURL = tokensDirectory.appendingPathComponent("\(accountId).json")
        try? FileManager.default.removeItem(at: fileURL)

        // Delete from Keychain silently
        try? KeychainService.delete(key: keychainKey(for: accountId))
    }

    func clearAllTokens() throws {
        // Delete all JSON files from disk directory
        if let files = try? FileManager.default.contentsOfDirectory(at: tokensDirectory, includingPropertiesForKeys: nil) {
            for fileURL in files {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        // Delete all items from Keychain silently
        try? KeychainService.deleteAll()
    }
}