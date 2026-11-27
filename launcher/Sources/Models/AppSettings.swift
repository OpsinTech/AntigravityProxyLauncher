import Foundation

struct AppSettings: Codable, Equatable {
    var googleOAuthClientID: String
    var googleOAuthClientSecret: String
    var releaseFeedURL: String
    var releaseFeedTrustedHosts: String
    var releaseIgnoredVersion: String
    var hideDockIcon: Bool
    var githubToken: String
    var isActivated: Bool
    /// 退出 Launcher 后是否保留本地网关（18081）继续运行。
    /// true：网关由 launchd 常驻，可持续对外提供模型服务；false：随 Launcher 一起关闭。
    var keepGatewayAlive: Bool

    static let `default` = AppSettings(
        googleOAuthClientID: "",
        googleOAuthClientSecret: "",
        releaseFeedURL: "OpsinTech/AntigravityProxyLauncher",
        releaseFeedTrustedHosts: "github.com, api.github.com",
        releaseIgnoredVersion: "",
        hideDockIcon: false,
        githubToken: "",
        isActivated: false,
        keepGatewayAlive: true
    )

    enum CodingKeys: String, CodingKey {
        case googleOAuthClientID
        case googleOAuthClientSecret
        case releaseFeedURL
        case releaseFeedTrustedHosts
        case releaseIgnoredVersion
        case hideDockIcon
        case githubToken
        case isActivated = "diagnostic_reporting_opt_in"
        case keepGatewayAlive = "keep_gateway_alive"
    }

    init(
        googleOAuthClientID: String,
        googleOAuthClientSecret: String,
        releaseFeedURL: String,
        releaseFeedTrustedHosts: String,
        releaseIgnoredVersion: String,
        hideDockIcon: Bool,
        githubToken: String,
        isActivated: Bool,
        keepGatewayAlive: Bool
    ) {
        self.googleOAuthClientID = googleOAuthClientID
        self.googleOAuthClientSecret = googleOAuthClientSecret
        self.releaseFeedURL = releaseFeedURL
        self.releaseFeedTrustedHosts = releaseFeedTrustedHosts
        self.releaseIgnoredVersion = releaseIgnoredVersion
        self.hideDockIcon = hideDockIcon
        self.githubToken = githubToken
        self.isActivated = isActivated
        self.keepGatewayAlive = keepGatewayAlive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        googleOAuthClientID = try container.decodeIfPresent(String.self, forKey: .googleOAuthClientID) ?? ""
        googleOAuthClientSecret = try container.decodeIfPresent(String.self, forKey: .googleOAuthClientSecret) ?? ""
        releaseFeedURL = try container.decodeIfPresent(String.self, forKey: .releaseFeedURL) ?? "OpsinTech/AntigravityProxyLauncher"
        releaseFeedTrustedHosts = try container.decodeIfPresent(String.self, forKey: .releaseFeedTrustedHosts)
            ?? "github.com, api.github.com"
        releaseIgnoredVersion = try container.decodeIfPresent(String.self, forKey: .releaseIgnoredVersion) ?? ""
        hideDockIcon = try container.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? false
        githubToken = try container.decodeIfPresent(String.self, forKey: .githubToken) ?? ""
        isActivated = try container.decodeIfPresent(Bool.self, forKey: .isActivated) ?? false
        keepGatewayAlive = try container.decodeIfPresent(Bool.self, forKey: .keepGatewayAlive) ?? true
    }
}
