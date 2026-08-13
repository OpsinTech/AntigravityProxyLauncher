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
        guard httpResponse.statusCode == 200 else {
            throw ModelListError.httpError(httpResponse.statusCode)
        }

        let modelList = try JSONDecoder().decode(ModelListResponse.self, from: data)
        return modelList.data.map(\.id).sorted()
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
