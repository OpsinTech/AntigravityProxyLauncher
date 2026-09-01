import Foundation

/// Calls a provider's models endpoint to fetch available model IDs.
struct ModelListService {

    struct ModelEntry: Codable {
        let id: String
    }
    struct ModelListResponse: Codable {
        let data: [ModelEntry]
    }

    /// Fetch model IDs from an OpenAI-compatible provider.
    /// - Parameters:
    ///   - endpoint: API host (e.g. "api.deepseek.com")
    ///   - apiKey: Authentication key
    ///   - modelsPath: Path to the models listing endpoint (default "/v1/models")
    ///   - authHeader: HTTP header name for auth (default "Authorization")
    ///   - authPrefix: Prefix to prepend to the key (default "Bearer ")
    ///   - extraHeaders: Additional HTTP headers to include
    /// Returns model IDs sorted alphabetically, or throws on failure.
    func fetchModels(
        endpoint: String,
        apiKey: String,
        modelsPath: String = "/v1/models",
        authHeader: String = "Authorization",
        authPrefix: String = "Bearer ",
        extraHeaders: [String: String] = [:]
    ) async throws -> [String] {
        var scheme = "https"
        var host = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip trailing slash
        if host.hasSuffix("/") { host = String(host.dropLast()) }
        // Strip protocol if present, remembering whether it was http
        if host.hasPrefix("https://") { host = String(host.dropFirst(8)) }
        else if host.hasPrefix("http://") { host = String(host.dropFirst(7)); scheme = "http" }

        guard !host.isEmpty else { throw ModelListError.invalidEndpoint }

        let urlString = "\(scheme)://\(host)\(modelsPath)"
        guard let url = URL(string: urlString) else { throw ModelListError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !apiKey.isEmpty {
            request.setValue("\(authPrefix)\(apiKey)", forHTTPHeaderField: authHeader)
        }
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelListError.networkError
        }
        // Special handling for OpenRouter: parse metadata and filter out deprecated/low-quality items
        if host.contains("openrouter.ai") {
            let openRouterModels = parseOpenRouterModels(data: data)
            if !openRouterModels.isEmpty {
                return openRouterModels
            }
        }

        let modelList = try JSONDecoder().decode(ModelListResponse.self, from: data)
        return modelList.data.map(\.id).sorted()
    }

    // MARK: - OpenRouter Intelligent Filtering

    private struct OpenRouterModel: Codable {
        let id: String
        let name: String?
        let description: String?
        let contextLength: Int?
        let architecture: Architecture?
        let pricing: Pricing?

        struct Architecture: Codable {
            let modality: String?
            let outputModalities: [String]?

            enum CodingKeys: String, CodingKey {
                case modality
                case outputModalities = "output_modalities"
            }
        }

        struct Pricing: Codable {
            let prompt: String?
            let completion: String?
        }

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case description
            case contextLength = "context_length"
            case architecture
            case pricing
        }
    }

    private struct OpenRouterModelResponse: Codable {
        let data: [OpenRouterModel]
    }

    private func parseOpenRouterModels(data: Data) -> [String] {
        guard let response = try? JSONDecoder().decode(OpenRouterModelResponse.self, from: data) else {
            return []
        }

        // Filter out non-text models, embeddings, moderation/safety guard models
        let validModels = response.data.filter { model in
            let mid = model.id.lowercased()

            // Filter out non-text output models
            if let outputMods = model.architecture?.outputModalities, !outputMods.isEmpty {
                if !outputMods.contains("text") {
                    return false
                }
            }

            // Filter out non-chat / internal utility models
            let blacklistedSubstrings = ["guard", "safety", "moderation", "embed", "whisper", "tts", "dall-e", "midjourney"]
            if blacklistedSubstrings.contains(where: { mid.contains($0) }) {
                return false
            }

            return true
        }

        var freeModels: [String] = []
        var priorityPaidModels: [String] = []
        var otherPaidModels: [String] = []

        let priorityPrefixes = [
            "anthropic/claude-3.7", "anthropic/claude-3.5", "anthropic/claude-sonnet", "anthropic/claude-opus",
            "deepseek/deepseek-chat", "deepseek/deepseek-r1", "deepseek/deepseek-v3",
            "openai/gpt-4o", "openai/gpt-4.5", "openai/o1", "openai/o3",
            "google/gemini-2.5", "google/gemini-2.0", "google/gemini-flash",
            "meta-llama/llama-3.3", "meta-llama/llama-3.1",
            "qwen/qwen-2.5", "z-ai/glm-5", "minimax/minimax", "mistralai/mistral-large"
        ]

        for model in validModels {
            let mid = model.id
            let isFree = mid.hasSuffix(":free") ||
                (model.pricing?.prompt == "0" && model.pricing?.completion == "0")

            if isFree {
                freeModels.append(mid)
            } else if priorityPrefixes.contains(where: { mid.lowercased().hasPrefix($0) }) {
                priorityPaidModels.append(mid)
            } else {
                otherPaidModels.append(mid)
            }
        }

        freeModels.sort()
        priorityPaidModels.sort()
        otherPaidModels.sort()

        // Combine: Priority Flagship -> Curated Free -> Other Models
        return priorityPaidModels + freeModels + otherPaidModels
    }

    /// Probe connectivity by sending a minimal chat completion request.
    /// Returns the HTTP status code and a descriptive message.
    func probeEndpoint(
        endpoint: String,
        apiKey: String,
        apiPath: String = "/v1/chat/completions",
        authHeader: String = "Authorization",
        authPrefix: String = "Bearer ",
        extraHeaders: [String: String] = [:]
    ) async -> (ok: Bool, message: String) {
        var scheme = "https"
        var host = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasSuffix("/") { host = String(host.dropLast()) }
        if host.hasPrefix("https://") { host = String(host.dropFirst(8)) }
        else if host.hasPrefix("http://") { host = String(host.dropFirst(7)); scheme = "http" }

        guard !host.isEmpty else { return (false, "无效的 API 端点") }

        let urlString = "\(scheme)://\(host)\(apiPath)"
        guard let url = URL(string: urlString) else { return (false, "无效的 API 端点") }

        // Minimal streaming chat request to test connectivity
        // Some providers (e.g. CodeBuddy) require stream=true
        let body: [String: Any] = [
            "model": "ping",
            "messages": [
                ["role": "user", "content": "hi"]
            ],
            "max_tokens": 1,
            "stream": true
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("\(authPrefix)\(apiKey)", forHTTPHeaderField: authHeader)
        }
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.timeoutInterval = 10

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "网络请求失败")
            }

            // 4xx/5xx but NOT related to invalid model — even a model error means the endpoint is reachable
            if httpResponse.statusCode < 500 {
                // 2xx/3xx/4xx all indicate the endpoint is alive and auth works
                // (model name "ping" might cause 400/404 but that's expected)
                return (true, "端点可达 (状态 \(httpResponse.statusCode))")
            } else {
                let bodyStr = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                return (false, "服务端错误 (HTTP \(httpResponse.statusCode)): \(bodyStr)")
            }
        } catch {
            return (false, "连接失败: \(error.localizedDescription)")
        }
    }

    enum ModelListError: LocalizedError {
        case invalidEndpoint
        case networkError
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "无效的 API 端点"
            case .networkError: return "网络请求失败"
            case .httpError(let code): return "HTTP \(code)"
            }
        }
    }
}
