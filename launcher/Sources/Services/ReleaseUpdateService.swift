import Foundation

enum ReleaseUpdateError: Error {
    case invalidURL
    case untrustedSource(String)
    case fetchFailed(String)
    case rateLimited
    case decodeFailed
}

extension ReleaseUpdateError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "更新源地址无效，仅支持 http/https"
        case .untrustedSource(let host):
            return "更新源不在授信域名内: \(host)"
        case .fetchFailed(let reason):
            return "检查更新失败: \(reason)"
        case .rateLimited:
            return "GitHub API 请求频率超限，请稍后再试或在设置中配置 GitHub Token"
        case .decodeFailed:
            return "更新信息解析失败"
        }
    }
}

struct CachedReleaseInfo: Codable {
    let info: ReleaseUpdateInfoCodable
    let cachedAt: Date
    let etag: String?
}

struct ReleaseUpdateInfoCodable: Codable {
    let currentVersion: String
    let latestVersion: String
    let notes: String?
    let downloadURL: String?
    let isUpdateAvailable: Bool
}

extension ReleaseUpdateInfo {
    func toCodable() -> ReleaseUpdateInfoCodable {
        ReleaseUpdateInfoCodable(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            notes: notes,
            downloadURL: downloadURL,
            isUpdateAvailable: isUpdateAvailable
        )
    }

    static func fromCodable(_ codable: ReleaseUpdateInfoCodable) -> ReleaseUpdateInfo {
        ReleaseUpdateInfo(
            currentVersion: codable.currentVersion,
            latestVersion: codable.latestVersion,
            notes: codable.notes,
            downloadURL: codable.downloadURL,
            isUpdateAvailable: codable.isUpdateAvailable
        )
    }
}

struct ReleaseUpdateService {
    private static let cacheKey = "ReleaseUpdateCache"
    private static let cacheValidityDuration: TimeInterval = 3600 // 1 hour

    func check(
        currentVersion: String,
        urlString: String,
        trustedHostPatterns: [String]
    ) async throws -> ReleaseUpdateInfo {
        guard let url = URL(string: urlString), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw ReleaseUpdateError.invalidURL
        }

        let host = (url.host ?? "").lowercased()
        if !trustedHostPatterns.isEmpty {
            let matched = trustedHostPatterns.contains { pattern in
                let normalized = pattern.lowercased()
                return host == normalized || host.hasSuffix("." + normalized)
            }
            if !matched {
                throw ReleaseUpdateError.untrustedSource(host)
            }
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ReleaseUpdateError.fetchFailed("HTTP \(http.statusCode)")
        }

        let payload: ReleaseFeedPayload
        do {
            payload = try JSONDecoder().decode(ReleaseFeedPayload.self, from: data)
        } catch {
            throw ReleaseUpdateError.decodeFailed
        }

        let available = compareVersion(payload.latestVersion, currentVersion) > 0
        return ReleaseUpdateInfo(
            currentVersion: currentVersion,
            latestVersion: payload.latestVersion,
            notes: payload.notes,
            downloadURL: payload.downloadURL,
            isUpdateAvailable: available
        )
    }

    /// Check for updates via the GitHub Releases API.
    /// - Parameters:
    ///   - owner: GitHub repo owner (e.g. "KevinLiangX")
    ///   - repo: GitHub repo name (e.g. "AntigravityProxyLauncher")
    ///   - currentVersion: the running app version (without "v" prefix)
    ///   - githubToken: optional GitHub Personal Access Token for higher rate limits
    ///   - forceRefresh: bypass cache and fetch fresh data
    func checkGitHubRepo(owner: String, repo: String, currentVersion: String,
                         platform: String = "macos",
                         githubToken: String? = nil,
                         forceRefresh: Bool = false) async throws -> ReleaseUpdateInfo {
        let cached = loadCachedInfo(owner: owner, repo: repo, platform: platform)

        // Use cache if valid and force refresh not requested.
        // But always make a lightweight ETag request to check for updates.
        if !forceRefresh, let cached {
            // Try ETag conditional request first (304 = no change, doesn't consume quota)
            if let etag = cached.etag {
                let apiURL = "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=30"
                guard let url = URL(string: apiURL) else {
                    throw ReleaseUpdateError.invalidURL
                }
                var req = URLRequest(url: url, timeoutInterval: 10)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.setValue("AntigravityProxyLauncher/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                req.setValue(etag, forHTTPHeaderField: "If-None-Match")
                let token = (githubToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }

                if let (_, resp) = try? await URLSession.shared.data(for: req),
                   let http = resp as? HTTPURLResponse,
                   http.statusCode == 304 {
                    // No new release, use cache
                    let available = compareVersion(cached.info.latestVersion, currentVersion) > 0
                    return ReleaseUpdateInfo(
                        currentVersion: currentVersion,
                        latestVersion: cached.info.latestVersion,
                        notes: cached.info.notes,
                        downloadURL: cached.info.downloadURL,
                        isUpdateAvailable: available
                    )
                }
                // ETag request failed or returned 200 — fall through to full fetch
            } else {
                // No ETag cached, use cached result as-is
                let available = compareVersion(cached.info.latestVersion, currentVersion) > 0
                return ReleaseUpdateInfo(
                    currentVersion: currentVersion,
                    latestVersion: cached.info.latestVersion,
                    notes: cached.info.notes,
                    downloadURL: cached.info.downloadURL,
                    isUpdateAvailable: available
                )
            }
        }

        // Full fetch: no cache, force refresh, or ETag indicated new data
        let apiURL = "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=30"
        guard let url = URL(string: apiURL) else {
            throw ReleaseUpdateError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AntigravityProxyLauncher/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        // Add GitHub Token if available
        let token = (githubToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Add ETag for conditional request
        if let cached, let etag = cached.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ReleaseUpdateError.fetchFailed("无效的响应")
        }

        // Handle 304 Not Modified (conditional request)
        if http.statusCode == 304 {
            if let cached = loadCachedInfo(owner: owner, repo: repo, platform: platform) {
                let available = compareVersion(cached.info.latestVersion, currentVersion) > 0
                return ReleaseUpdateInfo(
                    currentVersion: currentVersion,
                    latestVersion: cached.info.latestVersion,
                    notes: cached.info.notes,
                    downloadURL: cached.info.downloadURL,
                    isUpdateAvailable: available
                )
            }
        }

        // Handle rate limiting (403 or 429)
        if http.statusCode == 403 || http.statusCode == 429 {
            // Check if we have cached data to fall back on
            if let cached = loadCachedInfo(owner: owner, repo: repo, platform: platform) {
                let available = compareVersion(cached.info.latestVersion, currentVersion) > 0
                return ReleaseUpdateInfo(
                    currentVersion: currentVersion,
                    latestVersion: cached.info.latestVersion,
                    notes: cached.info.notes,
                    downloadURL: cached.info.downloadURL,
                    isUpdateAvailable: available
                )
            }
            throw ReleaseUpdateError.rateLimited
        }

        if !(200...299).contains(http.statusCode) {
            throw ReleaseUpdateError.fetchFailed("GitHub API HTTP \(http.statusCode)")
        }

        guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ReleaseUpdateError.decodeFailed
        }

        // Find the first (most recent) release matching the platform suffix, e.g. "v2.3.0-macos"
        let suffix = "-\(platform)"
        guard let match = releases.first(where: { ($0["tag_name"] as? String ?? "").hasSuffix(suffix) }),
              let rawTag = match["tag_name"] as? String else {
            throw ReleaseUpdateError.decodeFailed
        }

        // Strip suffix and leading "v" for version comparison
        var versionPart = rawTag
        if versionPart.hasSuffix(suffix) {
            versionPart = String(versionPart.dropLast(suffix.count))
        }
        if versionPart.hasPrefix("v") {
            versionPart = String(versionPart.dropFirst())
        }
        guard !versionPart.isEmpty else {
            throw ReleaseUpdateError.decodeFailed
        }

        let body = match["body"] as? String
        let htmlURL = match["html_url"] as? String

        let available = compareVersion(versionPart, currentVersion) > 0
        let result = ReleaseUpdateInfo(
            currentVersion: currentVersion,
            latestVersion: versionPart,
            notes: body,
            downloadURL: htmlURL,
            isUpdateAvailable: available
        )

        // Cache the result with ETag
        let etag = http.value(forHTTPHeaderField: "ETag")
        saveCacheInfo(info: result.toCodable(), owner: owner, repo: repo, platform: platform, etag: etag)

        return result
    }

    // MARK: - Cache Management

    private func cacheKeyFor(owner: String, repo: String, platform: String) -> String {
        "\(Self.cacheKey)_\(owner)_\(repo)_\(platform)"
    }

    private func loadCachedInfo(owner: String, repo: String, platform: String) -> CachedReleaseInfo? {
        let key = cacheKeyFor(owner: owner, repo: repo, platform: platform)
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(CachedReleaseInfo.self, from: data) else {
            return nil
        }

        // Check if cache is still valid
        let elapsed = Date().timeIntervalSince(cached.cachedAt)
        if elapsed > Self.cacheValidityDuration {
            return nil
        }

        return cached
    }

    private func saveCacheInfo(info: ReleaseUpdateInfoCodable, owner: String, repo: String, platform: String, etag: String?) {
        let key = cacheKeyFor(owner: owner, repo: repo, platform: platform)
        let cached = CachedReleaseInfo(info: info, cachedAt: Date(), etag: etag)
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func clearCache(owner: String, repo: String, platform: String = "macos") {
        let key = cacheKeyFor(owner: owner, repo: repo, platform: platform)
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        lhs.compare(rhs, options: .numeric).rawValue
    }
}
