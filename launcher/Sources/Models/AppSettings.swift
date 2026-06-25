import Foundation

struct AppSettings: Codable, Equatable {
    var quotaAutoRefreshEnabled: Bool
    var quotaPollingIntervalSeconds: Int
    var googleOAuthClientID: String
    var googleOAuthClientSecret: String
    var releaseFeedURL: String
    var releaseFeedTrustedHosts: String
    var releaseIgnoredVersion: String
    var hideDockIcon: Bool
    var githubToken: String

    static let `default` = AppSettings(
        quotaAutoRefreshEnabled: false,
        quotaPollingIntervalSeconds: 60,
        googleOAuthClientID: "",
        googleOAuthClientSecret: "",
        releaseFeedURL: "OpsinTech/AntigravityProxyLauncher",
        releaseFeedTrustedHosts: "github.com, api.github.com",
        releaseIgnoredVersion: "",
        hideDockIcon: false,
        githubToken: ""
    )

    enum CodingKeys: String, CodingKey {
        case quotaAutoRefreshEnabled
        case quotaPollingIntervalSeconds
        case googleOAuthClientID
        case googleOAuthClientSecret
        case releaseFeedURL
        case releaseFeedTrustedHosts
        case releaseIgnoredVersion
        case hideDockIcon
        case githubToken
    }

    init(
        quotaAutoRefreshEnabled: Bool,
        quotaPollingIntervalSeconds: Int,
        googleOAuthClientID: String,
        googleOAuthClientSecret: String,
        releaseFeedURL: String,
        releaseFeedTrustedHosts: String,
        releaseIgnoredVersion: String,
        hideDockIcon: Bool,
        githubToken: String
    ) {
        self.quotaAutoRefreshEnabled = quotaAutoRefreshEnabled
        self.quotaPollingIntervalSeconds = quotaPollingIntervalSeconds
        self.googleOAuthClientID = googleOAuthClientID
        self.googleOAuthClientSecret = googleOAuthClientSecret
        self.releaseFeedURL = releaseFeedURL
        self.releaseFeedTrustedHosts = releaseFeedTrustedHosts
        self.releaseIgnoredVersion = releaseIgnoredVersion
        self.hideDockIcon = hideDockIcon
        self.githubToken = githubToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quotaAutoRefreshEnabled = try container.decodeIfPresent(Bool.self, forKey: .quotaAutoRefreshEnabled) ?? false
        quotaPollingIntervalSeconds = max(5, try container.decodeIfPresent(Int.self, forKey: .quotaPollingIntervalSeconds) ?? 60)
        googleOAuthClientID = try container.decodeIfPresent(String.self, forKey: .googleOAuthClientID) ?? ""
        googleOAuthClientSecret = try container.decodeIfPresent(String.self, forKey: .googleOAuthClientSecret) ?? ""
        releaseFeedURL = try container.decodeIfPresent(String.self, forKey: .releaseFeedURL) ?? "OpsinTech/AntigravityProxyLauncher"
        releaseFeedTrustedHosts = try container.decodeIfPresent(String.self, forKey: .releaseFeedTrustedHosts)
            ?? "github.com, api.github.com"
        releaseIgnoredVersion = try container.decodeIfPresent(String.self, forKey: .releaseIgnoredVersion) ?? ""
        hideDockIcon = try container.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? false
        githubToken = try container.decodeIfPresent(String.self, forKey: .githubToken) ?? ""
    }
}
