import Foundation

/// LLMRouter 的虚拟 Provider ID，映射到此值时进入关键词路由子系统
let LLMRouterProviderID = "llm_router"

/// Gemini 内置 Provider ID：路由目标选择此值时，请求改 model 后直接走应用
/// 自身的 Gemini 后端（透传），无需第三方 provider 配置或 API Key。
let GeminiBuiltinProviderID = "gemini_builtin"

/// 内置 Gemini 模型列表 —— 模型 ID 与显示名（来自 daily-cloudcode-pa fetchAvailableModels 真实响应）
struct GeminiBuiltinModel: Identifiable, Hashable {
    let id: String          // 实际 API model ID（后端要求的 ID）
    let displayName: String // UI 展示名

    init(_ id: String, _ displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// 内置 Gemini 模型列表（2026-08-18 从 daily-cloudcode-pa.googleapis.com fetchAvailableModels 抓取的真实可用 ID）
/// 注意：后端要求带后缀的 ID（-high/-low/-medium/-tiered/-agent 等），裸 ID（如 gemini-3.6-flash）会返回 404。
/// 显示名直接取自 fetchAvailableModels 响应的 display name（个别为 "-" 的 tiered 模型按同族命名）。
let GeminiBuiltinModels: [GeminiBuiltinModel] = [
    GeminiBuiltinModel("gemini-3.7-flash-high", "Gemini 3.7 Flash (High)"),
    GeminiBuiltinModel("gemini-3.7-flash-low", "Gemini 3.7 Flash (Low)"),
    GeminiBuiltinModel("gemini-3.7-flash-medium", "Gemini 3.7 Flash (Medium)"),
    GeminiBuiltinModel("gemini-3.7-flash-tiered", "Gemini 3.7 Flash (Tiered)"),
    GeminiBuiltinModel("gemini-3.6-flash-high", "Gemini 3.6 Flash (High)"),
    GeminiBuiltinModel("gemini-3.6-flash-low", "Gemini 3.6 Flash (Low)"),
    GeminiBuiltinModel("gemini-3.6-flash-medium", "Gemini 3.6 Flash (Medium)"),
    GeminiBuiltinModel("gemini-3.6-flash-tiered", "Gemini 3.6 Flash (Tiered)"),
    GeminiBuiltinModel("gemini-3.5-flash-extra-low", "Gemini 3.5 Flash (Low)"),
    GeminiBuiltinModel("gemini-3.5-flash-low", "Gemini 3.5 Flash (Medium)"),
    GeminiBuiltinModel("gemini-3-flash-agent", "Gemini 3.5 Flash (High)"),
    GeminiBuiltinModel("gemini-3-flash", "Gemini 3 Flash"),
    GeminiBuiltinModel("gemini-3.1-pro-high", "Gemini 3.1 Pro (High)"),
    GeminiBuiltinModel("gemini-3.1-pro-low", "Gemini 3.1 Pro (Low)"),
    GeminiBuiltinModel("gemini-pro-agent", "Gemini 3.1 Pro (High)"),
    GeminiBuiltinModel("gemini-3.1-flash-image", "Gemini 3.1 Flash Image"),
    GeminiBuiltinModel("gemini-3.1-flash-lite", "Gemini 3.1 Flash Lite"),
    GeminiBuiltinModel("gemini-2.5-flash", "Gemini 3.1 Flash Lite"),
    GeminiBuiltinModel("gemini-2.5-flash-lite", "Gemini 3.1 Flash Lite"),
    GeminiBuiltinModel("gemini-2.5-flash-thinking", "Gemini 3.1 Flash Lite"),
    GeminiBuiltinModel("gemini-2.5-pro", "Gemini 2.5 Pro"),
]

struct ModelRoutingConfig: Codable, Equatable {
    var version: String = "1.0"
    var providers: [ProviderConfig] = []
    var routingRules: [RoutingRule] = []
    var llmRouter: LLMRouterConfig? = nil

    /// 确保内置服务商（DeepSeek / OfoxAI / CodeBuddy / TokenRouter）及三个本地模型服务（Ollama / vLLM / LM Studio）始终存在。
    /// 按 id 前缀去重：若用户已配置过，不再重复添加，因此不会覆盖用户在卡片里修改的 endpoint / 启用状态。
    mutating func ensureBuiltinLocalProviders() {
        for defaultP in Self.defaultProviders {
            if !providers.contains(where: { $0.id == defaultP.id }) {
                providers.append(defaultP)
            }
        }
        for kind in LocalModelServiceKind.allCases {
            let prefix = "local-\(kind.rawValue)-"
            let exists = providers.contains { $0.id.hasPrefix(prefix) }
            if !exists {
                providers.append(ProviderConfig.localTemplate(kind))
            }
        }
    }

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

        /// 本地模型服务模板（ollama / vLLM / LM Studio）。
        /// 三者均暴露 OpenAI 兼容接口，type 统一为 "openai"，默认开启 auto_models
        /// 自动从 /v1/models 同步模型列表（不写死模型名，避免与本地实际加载不一致）。
        static func localTemplate(_ kind: LocalModelServiceKind) -> ModelRoutingConfig.ProviderConfig {
            ModelRoutingConfig.ProviderConfig(
                id: "local-\(kind.rawValue)-\(UUID().uuidString.prefix(8))",
                name: kind.displayName,
                enabled: false,
                type: "openai",
                apiEndpoint: kind.defaultEndpoint,
                apiKey: "",
                models: [],
                options: ["auto_models": "true"]
            )
        }
    }

    /// 支持通过 UI 一键添加的本地模型服务类型。
    /// 均为 OpenAI 兼容，复用 openai provider（http scheme + auto_models）。
    enum LocalModelServiceKind: String, CaseIterable, Identifiable {
        case ollama
        case vllm
        case lmstudio

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .ollama:   return "Ollama"
            case .vllm:     return "vLLM"
            case .lmstudio: return "LM Studio"
            }
        }

        /// 默认暴露的本地接入点（OpenAI 兼容 /v1/chat/completions）
        var defaultEndpoint: String {
            switch self {
            case .ollama:   return "http://localhost:11434"
            case .vllm:     return "http://localhost:8000"
            case .lmstudio: return "http://localhost:1234"
            }
        }

        var website: URL? {
            switch self {
            case .ollama:   return URL(string: "https://ollama.com")
            case .vllm:     return URL(string: "https://docs.vllm.ai")
            case .lmstudio: return URL(string: "https://lmstudio.ai")
            }
        }

        var systemImage: String {
            switch self {
            case .ollama:   return "server.rack"
            case .vllm:     return "cpu"
            case .lmstudio: return "slider.horizontal.3"
            }
        }
    }

    struct RoutingRule: Codable, Equatable, Identifiable {
        var id: String = UUID().uuidString
        var sourceModelPattern: String
        var sourceDisplayName: String
        var sourceType: String? = nil
        var targetProviderID: String?
        var targetModel: String?
        var enabled: Bool = true

        enum CodingKeys: String, CodingKey {
            case id
            case sourceModelPattern = "source_model_pattern"
            case sourceDisplayName = "source_display_name"
            case sourceType = "source_type"
            case targetProviderID = "target_provider_id"
            case targetModel = "target_model"
            case enabled
        }
    }

    /// LLMRouter 关键词路由规则
    struct LLMRouterRule: Codable, Equatable, Identifiable {
        var id: String = UUID().uuidString
        var keywords: [String] = []
        var matchMode: String = "any"  // "any" 或 "all"
        var targetProviderID: String = ""
        var targetModel: String = ""
        var enabled: Bool = true

        enum CodingKeys: String, CodingKey {
            case id
            case keywords
            case matchMode = "match_mode"
            case targetProviderID = "target_provider_id"
            case targetModel = "target_model"
            case enabled
        }
    }

    /// LLMRouter 配置
    struct LLMRouterConfig: Codable, Equatable {
        var enabled: Bool = false
        var defaultModel: String = ""
        var defaultProviderID: String = ""
        var rules: [LLMRouterRule] = []

        enum CodingKeys: String, CodingKey {
            case enabled
            case defaultModel = "default_model"
            case defaultProviderID = "default_provider_id"
            case rules
        }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case providers
        case routingRules = "routing_rules"
        case llmRouter = "llm_router"
    }
}

extension ModelRoutingConfig {
    /// Shared default providers (used by both ecosystems).
    static let defaultProviders: [ProviderConfig] = [
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
                "glm-5.0",
                "kimi-k3",
                "kimi-k2.7",
                "kimi-k2.6",
                "kimi-k2.5",
                "deepseek-v4-pro",
                "deepseek-v4-flash",
                "deepseek-v3",
                "deepseek-r1",
                "hunyuan-chat",
                "hy3",
                "hy4-preview"
                // TODO: 限免版 hy4 模型 ID 待确认后在此追加（例如 hy4-preview-free / hy4-xxx）
            ],
            options: [
                "api_path": "/v2/chat/completions"
            ]
        ),
        ProviderConfig(
            id: "tokenrouter",
            name: "TokenRouter",
            enabled: false,
            apiEndpoint: "api.tokenrouter.com",
            apiKey: "",
            models: [
                "anthropic/claude-sonnet-4-6",
                "anthropic/claude-opus-4-6",
                "anthropic/claude-3-7-sonnet",
                "anthropic/claude-3-5-sonnet",
                "deepseek/deepseek-chat",
                "deepseek/deepseek-reasoner",
                "openai/gpt-4o",
                "openai/gpt-4.5-preview"
            ],
            options: [
                "auto_models": "true"
            ]
        ),
        ProviderConfig(
            id: "openrouter",
            name: "OpenRouter",
            enabled: false,
            apiEndpoint: "openrouter.ai",
            apiKey: "",
            models: [
                // Top Mainstream Flagship Models
                "anthropic/claude-3.7-sonnet",
                "anthropic/claude-3.5-sonnet",
                "deepseek/deepseek-chat",
                "deepseek/deepseek-r1",
                "openai/gpt-4o",
                "openai/gpt-4.5-preview",
                "meta-llama/llama-3.3-70b-instruct",
                "google/gemini-2.5-pro",
                "google/gemini-2.5-flash",
                // Top Curated Free Models
                "liquid/lfm-2.5-2.6b:free",
                "nvidia/nemotron-3.5-lightning:free",
                "z-ai/glm-5.2:free",
                "cohere/north-mini-code:free",
                "minimax/minimax-m3:free",
                "thinkingmachines/inkling:free"
            ],
            options: [
                "api_path": "/api/v1/chat/completions",
                "auto_models": "true"
            ]
        ),
    ]

    /// Google ecosystem default routing rules.
    static let defaultGoogleRules: [RoutingRule] = [
        RoutingRule(
            sourceModelPattern: "claude-sonnet-4-6",
            sourceDisplayName: "Claude Sonnet 4.6",
            sourceType: "google",
            targetProviderID: "deepseek",
            targetModel: "deepseek-v4-flash",
            enabled: true
        ),
        RoutingRule(
            sourceModelPattern: "claude-opus-4-6",
            sourceDisplayName: "Claude Opus 4.6",
            sourceType: "google",
            targetProviderID: "deepseek",
            targetModel: "deepseek-v4-pro",
            enabled: true
        ),
        RoutingRule(
            sourceModelPattern: "gpt-oss-120b",
            sourceDisplayName: "GPT OSS 120B",
            sourceType: "google",
            targetProviderID: "deepseek",
            targetModel: "deepseek-v4-flash",
            enabled: true
        ),
    ]

    /// Default config (Google ecosystem only).
    static let `default` = ModelRoutingConfig(
        providers: defaultProviders,
        routingRules: defaultGoogleRules
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

    /// Returns routing rules filtered by source type.
    func rules(for sourceType: String) -> [RoutingRule] {
        routingRules.filter { $0.sourceType == sourceType }
    }

    /// Merge this config with another, producing a combined config suitable for the Go proxy.
    /// Providers are deduplicated by ID (keeping the first occurrence).
    /// Routing rules from both configs are concatenated.
}
