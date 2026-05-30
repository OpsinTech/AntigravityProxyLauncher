import Foundation

enum QuotaApiError: Error {
    case unauthorized(String)
    case rateLimited(String)
    case serverError(Int, String)
    case badRequest(Int, String)
    case network(String)
    case parse(String)
}

extension QuotaApiError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthorized(let message):
            return "未授权: \(message)"
        case .rateLimited(let message):
            return "请求过于频繁: \(message)"
        case .serverError(let code, let message):
            return "服务端错误(\(code)): \(message)"
        case .badRequest(let code, let message):
            return "请求失败(\(code)): \(message)"
        case .network(let message):
            return "网络错误: \(message)"
        case .parse(let message):
            return "解析错误: \(message)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .rateLimited:
            return true
        case .serverError:
            return true
        default:
            return false
        }
    }

    var needsReauth: Bool {
        if case .unauthorized = self {
            return true
        }
        return false
    }
}

struct QuotaApiClient {
    private let session: URLSession
    private let baseURL = URL(string: "https://cloudcode-pa.googleapis.com")!
    private let apiTimeoutSeconds: TimeInterval

    init(session: URLSession = .shared, apiTimeoutSeconds: TimeInterval = 10) {
        self.session = session
        self.apiTimeoutSeconds = apiTimeoutSeconds
    }

    func loadProjectInfo(accessToken: String, ideType: String) async throws -> ProjectInfo {
        let response = try await makeApiRequest(
            path: "/v1internal:loadCodeAssist",
            accessToken: accessToken,
            body: ["metadata": ["ideType": ideType]]
        )

        let projectId = response["cloudaicompanionProject"] as? String ?? ""
        let paidTier = (response["paidTier"] as? [String: Any])?["id"] as? String
        let currentTier = (response["currentTier"] as? [String: Any])?["id"] as? String
        let tier = paidTier ?? currentTier ?? "FREE"

        return ProjectInfo(projectId: projectId, tier: tier)
    }

    func fetchModelsQuota(accessToken: String, projectId: String) async throws -> [ModelQuotaInfo] {
        let response = try await makeApiRequest(
            path: "/v1internal:fetchAvailableModels",
            accessToken: accessToken,
            body: ["project": projectId]
        )

        guard let modelsMap = response["models"] as? [String: Any] else {
            return []
        }

        var models: [ModelQuotaInfo] = []

        for (modelName, value) in modelsMap {
            guard isAllowedModelName(modelName), isModelVersionSupported(modelName) else {
                continue
            }
            guard let modelInfo = value as? [String: Any] else {
                continue
            }
            guard let quotaInfo = modelInfo["quotaInfo"] as? [String: Any] else {
                continue
            }

            // If remainingFraction is absent, skip the model rather than
            // defaulting to 0 (which would falsely show it as exhausted).
            guard let fraction = quotaInfo["remainingFraction"] as? Double else {
                continue
            }
            let resetRaw = quotaInfo["resetTime"] as? String ?? ""
            let resetTime = parseResetTime(resetRaw)

            let model = ModelQuotaInfo(
                modelId: modelName,
                displayName: formatDisplayName(modelName),
                remainingFraction: fraction,
                remainingPercentage: fraction * 100,
                isExhausted: fraction <= 0,
                resetTime: resetTime
            )
            models.append(model)
        }

        return models.sorted { $0.remainingPercentage > $1.remainingPercentage }
    }

    private func parseResetTime(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        // Common RFC3339 / ISO8601 format
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        // Variant with fractional seconds
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: trimmed) {
            return date
        }

        // Some backends may return epoch seconds/milliseconds as string
        if let epoch = Double(trimmed) {
            return epoch > 9_999_999_999 ? Date(timeIntervalSince1970: epoch / 1000) : Date(timeIntervalSince1970: epoch)
        }

        return nil
    }

    private func makeApiRequest(path: String, accessToken: String, body: [String: Any]) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: apiTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Antigravity/1.11", forHTTPHeaderField: "User-Agent")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw QuotaApiError.parse("请求体序列化失败")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw QuotaApiError.network("无效响应")
            }

            if !(200...299).contains(http.statusCode) {
                let message = parseErrorMessage(data: data) ?? "Unknown error"
                switch http.statusCode {
                case 401:
                    throw QuotaApiError.unauthorized(message)
                case 429:
                    throw QuotaApiError.rateLimited(message)
                case 500...599:
                    throw QuotaApiError.serverError(http.statusCode, message)
                default:
                    throw QuotaApiError.badRequest(http.statusCode, message)
                }
            }

            let object = try JSONSerialization.jsonObject(with: data)
            guard let dict = object as? [String: Any] else {
                throw QuotaApiError.parse("响应不是对象")
            }
            return dict
        } catch let apiError as QuotaApiError {
            throw apiError
        } catch {
            throw QuotaApiError.network(error.localizedDescription)
        }
    }

    private func parseErrorMessage(data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }

        if let error = dict["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return dict["message"] as? String
    }

    private func isAllowedModelName(_ modelName: String) -> Bool {
        modelName.range(of: "gemini|claude|gpt", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func isModelVersionSupported(_ modelName: String) -> Bool {
        let lower = modelName.lowercased()
        guard lower.contains("gemini") else {
            return true
        }

        guard let range = lower.range(of: "gemini-(\\d+(?:\\.\\d+)?)", options: .regularExpression) else {
            return false
        }

        let matched = String(lower[range]).replacingOccurrences(of: "gemini-", with: "")
        guard let version = Double(matched) else {
            return false
        }
        return version >= 3.0
    }

    private func formatDisplayName(_ modelName: String) -> String {
        let fixed = modelName.replacingOccurrences(of: "(\\d+)-(\\d+)", with: "$1.$2", options: .regularExpression)
        return fixed
            .split(separator: "-")
            .map { part in
                if part.first?.isNumber == true {
                    return String(part)
                }
                return part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }
}
