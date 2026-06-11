import Foundation

struct AppSettings: Codable, Equatable {
    var autoExportDiagnosticsOnFailure: Bool
    var quotaAutoRefreshEnabled: Bool
    var quotaPollingIntervalSeconds: Int
    var googleOAuthClientID: String
    var googleOAuthClientSecret: String
    var compatibilityRulesURL: String
    var compatibilityTrustedHosts: String
    var compatibilityExpectedSHA256: String
    var releaseFeedURL: String
    var releaseFeedTrustedHosts: String
    var releaseIgnoredVersion: String
    var enableRuntimeLog: Bool
    var runtimeLogRefreshInterval: Int
    var runtimeLogLevel: String
    var autoLaunchAfterPatch: Bool
    var hideDockIcon: Bool
    var githubToken: String

    static let `default` = AppSettings(
        autoExportDiagnosticsOnFailure: true,
        quotaAutoRefreshEnabled: false,
        quotaPollingIntervalSeconds: 60,
        googleOAuthClientID: "",
        googleOAuthClientSecret: "",
        compatibilityRulesURL: "",
        compatibilityTrustedHosts: "githubusercontent.com, raw.githubusercontent.com",
        compatibilityExpectedSHA256: "",
        releaseFeedURL: "OpsinTech/AntigravityProxyLauncher",
        releaseFeedTrustedHosts: "github.com, api.github.com",
        releaseIgnoredVersion: "",
        enableRuntimeLog: false,
        runtimeLogRefreshInterval: 5,
        runtimeLogLevel: "Info",
        autoLaunchAfterPatch: false,
        hideDockIcon: false,
        githubToken: ""
    )

    enum CodingKeys: String, CodingKey {
        case autoExportDiagnosticsOnFailure
        case quotaAutoRefreshEnabled
        case quotaPollingIntervalSeconds
        case googleOAuthClientID
        case googleOAuthClientSecret
        case compatibilityRulesURL
        case compatibilityTrustedHosts
        case compatibilityExpectedSHA256
        case releaseFeedURL
        case releaseFeedTrustedHosts
        case releaseIgnoredVersion
        case enableRuntimeLog
        case runtimeLogRefreshInterval
        case runtimeLogLevel
        case autoLaunchAfterPatch
        case hideDockIcon
        case githubToken
    }

    init(
        autoExportDiagnosticsOnFailure: Bool,
        quotaAutoRefreshEnabled: Bool,
        quotaPollingIntervalSeconds: Int,
        googleOAuthClientID: String,
        googleOAuthClientSecret: String,
        compatibilityRulesURL: String,
        compatibilityTrustedHosts: String,
        compatibilityExpectedSHA256: String,
        releaseFeedURL: String,
        releaseFeedTrustedHosts: String,
        releaseIgnoredVersion: String,
        enableRuntimeLog: Bool,
        runtimeLogRefreshInterval: Int,
        runtimeLogLevel: String,
        autoLaunchAfterPatch: Bool,
        hideDockIcon: Bool,
        githubToken: String
    ) {
        self.autoExportDiagnosticsOnFailure = autoExportDiagnosticsOnFailure
        self.quotaAutoRefreshEnabled = quotaAutoRefreshEnabled
        self.quotaPollingIntervalSeconds = quotaPollingIntervalSeconds
        self.googleOAuthClientID = googleOAuthClientID
        self.googleOAuthClientSecret = googleOAuthClientSecret
        self.compatibilityRulesURL = compatibilityRulesURL
        self.compatibilityTrustedHosts = compatibilityTrustedHosts
        self.compatibilityExpectedSHA256 = compatibilityExpectedSHA256
        self.releaseFeedURL = releaseFeedURL
        self.releaseFeedTrustedHosts = releaseFeedTrustedHosts
        self.releaseIgnoredVersion = releaseIgnoredVersion
        self.enableRuntimeLog = enableRuntimeLog
        self.runtimeLogRefreshInterval = runtimeLogRefreshInterval
        self.runtimeLogLevel = runtimeLogLevel
        self.autoLaunchAfterPatch = autoLaunchAfterPatch
        self.hideDockIcon = hideDockIcon
        self.githubToken = githubToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoExportDiagnosticsOnFailure = try container.decodeIfPresent(Bool.self, forKey: .autoExportDiagnosticsOnFailure) ?? true
        quotaAutoRefreshEnabled = try container.decodeIfPresent(Bool.self, forKey: .quotaAutoRefreshEnabled) ?? false
        quotaPollingIntervalSeconds = max(5, try container.decodeIfPresent(Int.self, forKey: .quotaPollingIntervalSeconds) ?? 60)
        googleOAuthClientID = try container.decodeIfPresent(String.self, forKey: .googleOAuthClientID) ?? ""
        googleOAuthClientSecret = try container.decodeIfPresent(String.self, forKey: .googleOAuthClientSecret) ?? ""
        compatibilityRulesURL = try container.decodeIfPresent(String.self, forKey: .compatibilityRulesURL) ?? ""
        compatibilityTrustedHosts = try container.decodeIfPresent(String.self, forKey: .compatibilityTrustedHosts)
            ?? "githubusercontent.com, raw.githubusercontent.com"
        compatibilityExpectedSHA256 = try container.decodeIfPresent(String.self, forKey: .compatibilityExpectedSHA256) ?? ""
        releaseFeedURL = try container.decodeIfPresent(String.self, forKey: .releaseFeedURL) ?? "OpsinTech/AntigravityProxyLauncher"
        releaseFeedTrustedHosts = try container.decodeIfPresent(String.self, forKey: .releaseFeedTrustedHosts)
            ?? "github.com, api.github.com"
        releaseIgnoredVersion = try container.decodeIfPresent(String.self, forKey: .releaseIgnoredVersion) ?? ""
        enableRuntimeLog = try container.decodeIfPresent(Bool.self, forKey: .enableRuntimeLog) ?? false
        runtimeLogRefreshInterval = max(1, try container.decodeIfPresent(Int.self, forKey: .runtimeLogRefreshInterval) ?? 5)
        runtimeLogLevel = try container.decodeIfPresent(String.self, forKey: .runtimeLogLevel) ?? "Info"
        autoLaunchAfterPatch = try container.decodeIfPresent(Bool.self, forKey: .autoLaunchAfterPatch) ?? false
        hideDockIcon = try container.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? false
        githubToken = try container.decodeIfPresent(String.self, forKey: .githubToken) ?? ""
    }
}
