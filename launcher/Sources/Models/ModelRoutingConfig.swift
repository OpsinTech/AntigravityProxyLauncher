import Foundation

struct ModelRoutingConfig: Codable, Equatable {
    var version: String = "1.0"
    var providers: [ProviderConfig] = []
    var routingRules: [RoutingRule] = []

    struct ProviderConfig: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var enabled: Bool = false
        var type: String = "openai"
        var apiEndpoint: String
        var apiKey: String = ""
        var models: [String] = []
        var options: [String: String] = [:]

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case enabled
            case type
            case apiEndpoint = "api_endpoint"
            case apiKey = "api_key"
            case models
            case options
        }
    }

    struct RoutingRule: Codable, Equatable, Identifiable {
        var id: String = UUID().uuidString
        var sourceModelPattern: String
        var sourceDisplayName: String
        var targetProviderID: String?
        var targetModel: String?
        var enabled: Bool = true

        enum CodingKeys: String, CodingKey {
            case id
            case sourceModelPattern = "source_model_pattern"
            case sourceDisplayName = "source_display_name"
            case targetProviderID = "target_provider_id"
            case targetModel = "target_model"
            case enabled
        }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case providers
        case routingRules = "routing_rules"
    }
}

extension ModelRoutingConfig {
    static let `default` = ModelRoutingConfig(
        providers: [
            ProviderConfig(
                id: "deepseek",
                name: "DeepSeek",
                enabled: false,
                apiEndpoint: "api.deepseek.com",
                apiKey: "",
                models: ["deepseek-v4-flash", "deepseek-v4-pro", "deepseek-chat"]
            ),
            ProviderConfig(
                id: "ofox",
                name: "OfoxAI",
                enabled: false,
                apiEndpoint: "api.ofox.ai",
                apiKey: "",
                models: [
                    "anthropic/claude-sonnet-4-20250514",
                    "anthropic/claude-opus-4-20250514",
                    "openai/gpt-oss-120b"
                ]
            ),
            ProviderConfig(
                id: "codebuddy",
                name: "CodeBuddy",
                enabled: false,
                apiEndpoint: "copilot.tencent.com",
                apiKey: "",
                models: [
                    "glm-5.2",
                    "glm-5.1",
                    "kimi-k2.7-code",
                    "kimi-k2.6",
                    "deepseek-v4-flash",
                    "deepseek-v4-pro"
                ],
                options: [
                    "api_path": "/v2/chat/completions"
                ]
            ),
        ],
        routingRules: [
            RoutingRule(
                sourceModelPattern: "claude-sonnet-4-6",
                sourceDisplayName: "Claude Sonnet 4.6",
                targetProviderID: "deepseek",
                targetModel: "deepseek-v4-flash",
                enabled: true
            ),
            RoutingRule(
                sourceModelPattern: "claude-opus-4-6",
                sourceDisplayName: "Claude Opus 4.6",
                targetProviderID: "deepseek",
                targetModel: "deepseek-v4-pro",
                enabled: true
            ),
            RoutingRule(
                sourceModelPattern: "gpt-oss-120b",
                sourceDisplayName: "GPT OSS 120B",
                targetProviderID: "deepseek",
                targetModel: "deepseek-v4-flash",
                enabled: true
            )
        ]
    )
}

/// Convenience: find a provider by ID
extension ModelRoutingConfig {
    func provider(id: String) -> ProviderConfig? {
        providers.first { $0.id == id }
    }

    func enabledProviders() -> [ProviderConfig] {
        providers.filter { $0.enabled }
    }

    func enabledRules() -> [RoutingRule] {
        routingRules.filter { $0.enabled }
    }

    func apiKeyFor(providerID: String) -> String {
        provider(id: providerID)?.apiKey ?? ""
    }

    func endpointFor(providerID: String) -> String {
        provider(id: providerID)?.apiEndpoint ?? ""
    }
}
