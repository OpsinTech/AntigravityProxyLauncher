import Foundation

enum ReleaseUpdateError: Error {
    case invalidURL
    case untrustedSource(String)
    case fetchFailed(String)
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
        case .decodeFailed:
            return "更新信息解析失败"
        }
    }
}

struct ReleaseUpdateService {
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
    func checkGitHubRepo(owner: String, repo: String, currentVersion: String) async throws -> ReleaseUpdateInfo {
        let apiURL = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: apiURL) else {
            throw ReleaseUpdateError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AntigravityProxyLauncher/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ReleaseUpdateError.fetchFailed("GitHub API HTTP \(http.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReleaseUpdateError.decodeFailed
        }

        // GitHub returns tag_name like "v2.0.1" — strip leading "v" for comparison
        let rawTag = json["tag_name"] as? String ?? ""
        let latestVersion = rawTag.hasPrefix("v") ? String(rawTag.dropFirst()) : rawTag
        guard !latestVersion.isEmpty else {
            throw ReleaseUpdateError.decodeFailed
        }

        let body = json["body"] as? String
        let htmlURL = json["html_url"] as? String

        let available = compareVersion(latestVersion, currentVersion) > 0
        return ReleaseUpdateInfo(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            notes: body,
            downloadURL: htmlURL,
            isUpdateAvailable: available
        )
    }

    private func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        lhs.compare(rhs, options: .numeric).rawValue
    }
}