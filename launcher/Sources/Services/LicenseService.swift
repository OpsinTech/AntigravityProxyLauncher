import Foundation
import CryptoKit

enum LicenseServiceError: LocalizedError {
    case invalidKey
    case expired
    case alreadyActivated
    case networkError(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "License Key 无效"
        case .expired: return "License 已过期"
        case .alreadyActivated: return "该 License 已在其他设备激活"
        case .networkError(let msg): return "网络错误: \(msg)"
        case .serverError(let msg): return "服务器错误: \(msg)"
        }
    }
}

struct LicenseService {
    /// License API base URL. Set via LICENSE_API_URL env or use default.
    private var apiBaseURL: String {
        ProcessInfo.processInfo.environment["LICENSE_API_URL"]
            ?? "https://license.antigravity.yourdomain.com" // Replace with your domain
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Generate a machine identifier (stable across reboots, not across reinstalls)
    func generateMachineId() -> String {
        // Use platform serial number if available, otherwise fallback to hardware UUID
        let serial = platformSerialNumber()
            ?? hardwareUUID()
            ?? UUID().uuidString
        return SHA256.hash(data: Data(serial.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .lowercased()
    }

    /// Activate a license key for this machine
    func activate(key: String) async throws -> LicenseInfo {
        let machineId = generateMachineId()
        let body: [String: String] = ["licenseKey": key, "machineId": machineId]

        let response: LicenseAPIResponse = try await post("/activate", body: body)

        guard response.valid else {
            switch response.reason {
            case "expired": throw LicenseServiceError.expired
            case "already_activated": throw LicenseServiceError.alreadyActivated
            default: throw LicenseServiceError.invalidKey
            }
        }

        let expiresAt = parseDate(response.expiresAt) ?? Date().addingTimeInterval(30 * 86400)
        let activatedAt = parseDate(response.activatedAt) ?? Date()

        let info = LicenseInfo(
            licenseKey: key,
            plan: response.plan ?? "pro",
            expiresAt: expiresAt,
            activatedAt: activatedAt,
            machineId: machineId,
            lastVerifiedAt: Date()
        )

        // Save locally
        try saveLocal(info)
        return info
    }

    /// Verify license validity with server
    func verify() async throws -> LicenseInfo? {
        guard let local = try loadLocal() else { return nil }

        let body: [String: String] = [
            "licenseKey": local.licenseKey,
            "machineId": local.machineId,
        ]

        do {
            let response: LicenseAPIResponse = try await post("/verify", body: body)

            guard response.valid else {
                if response.reason == "expired" {
                    var expired = local
                    try saveLocal(expired) // Update local to reflect expiration
                }
                return local
            }

            let expiresAt = parseDate(response.expiresAt) ?? local.expiresAt
            let updated = LicenseInfo(
                licenseKey: local.licenseKey,
                plan: response.plan ?? local.plan,
                expiresAt: expiresAt,
                activatedAt: local.activatedAt,
                machineId: local.machineId,
                lastVerifiedAt: Date()
            )
            try saveLocal(updated)
            return updated
        } catch {
            // Offline: use cached data if within 7-day grace period
            if let cached = try? loadLocal(),
               cached.lastVerifiedAt.timeIntervalSinceNow > -7 * 86400 {
                return cached
            }
            return nil
        }
    }

    /// Load cached license info
    func loadLocal() throws -> LicenseInfo? {
        let url = licenseFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(LicenseInfo.self, from: data)
    }

    /// Save license info locally
    func saveLocal(_ info: LicenseInfo) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(info)
        try FileManager.default.createDirectory(
            at: licenseFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: licenseFileURL, options: .atomic)
    }

    /// Clear local license (for deactivation)
    func clearLocal() {
        try? FileManager.default.removeItem(at: licenseFileURL)
    }

    // MARK: - Private

    private var licenseFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/antigravity/license.json")
    }

    private func post(_ path: String, body: [String: String]) async throws -> LicenseAPIResponse {
        let url = URL(string: apiBaseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseServiceError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 429 {
            throw LicenseServiceError.serverError("请求过于频繁，请稍后再试")
        }

        let apiResponse = try decoder.decode(LicenseAPIResponse.self, from: data)
        return apiResponse
    }

    private func parseDate(_ str: String?) -> Date? {
        guard let str else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str) ?? ISO8601DateFormatter().date(from: str)
    }

    // MARK: - Hardware identifiers

    private func platformSerialNumber() -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments = ["-c", "IOPlatformExpertDevice", "-d", "2"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        // Extract "IOPlatformSerialNumber" = "XXXXXXXXXXXX"
        for line in output.split(separator: "\n") {
            if line.contains("IOPlatformSerialNumber"),
               let range = line.range(of: "\"([^\"]+)\"", options: .regularExpression) {
                var value = String(line[range])
                value = value.replacingOccurrences(of: "\"", with: "")
                return value
            }
        }
        return nil
    }

    private func hardwareUUID() -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/system_profiler"
        task.arguments = ["SPHardwareDataType"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.split(separator: "\n") {
            if line.contains("Hardware UUID") {
                return line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? nil
            }
        }
        return nil
    }
}
