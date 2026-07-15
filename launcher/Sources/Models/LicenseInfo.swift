import Foundation

struct LicenseInfo: Codable, Equatable {
    let licenseKey: String
    let plan: String
    let expiresAt: Date
    let activatedAt: Date?
    let machineId: String
    let lastVerifiedAt: Date

    var isExpired: Bool {
        Date() > expiresAt
    }

    var daysRemaining: Int {
        max(0, Int(ceil(expiresAt.timeIntervalSinceNow / 86400)))
    }

    var statusText: String {
        if isExpired {
            return "已过期"
        }
        if daysRemaining <= 7 {
            return "即将到期（剩余 \(daysRemaining) 天）"
        }
        return "有效（剩余 \(daysRemaining) 天）"
    }

    enum CodingKeys: String, CodingKey {
        case licenseKey = "license_key"
        case plan
        case expiresAt = "expires_at"
        case activatedAt = "activated_at"
        case machineId = "machine_id"
        case lastVerifiedAt = "last_verified_at"
    }
}

/// Response from license API
struct LicenseAPIResponse: Codable {
    let valid: Bool
    let reason: String?
    let plan: String?
    let expiresAt: String?
    let activatedAt: String?
    let daysRemaining: Int?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case valid, reason, plan, message
        case expiresAt = "expiresAt"
        case activatedAt = "activatedAt"
        case daysRemaining = "daysRemaining"
    }
}
