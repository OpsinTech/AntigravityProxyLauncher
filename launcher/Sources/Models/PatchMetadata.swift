import Foundation
import CryptoKit

struct PatchMetadata: Codable, Equatable {
    let launcherVersion: String
    let targetVersion: String
    let patchedAt: Date
    let dylibChecksum: String
    let configChecksum: String

    // License fields
    var licenseExpiresAt: Date?
    var licenseMachineId: String?
    var licenseHMAC: String?

    enum CodingKeys: String, CodingKey {
        case launcherVersion = "launcher_version"
        case targetVersion = "target_version"
        case patchedAt = "patched_at"
        case dylibChecksum = "dylib_checksum"
        case configChecksum = "config_checksum"
        case licenseExpiresAt = "license_expires_at"
        case licenseMachineId = "license_machine_id"
        case licenseHMAC = "license_hmac"
    }

    init(
        launcherVersion: String,
        targetVersion: String,
        patchedAt: Date,
        dylibChecksum: String,
        configChecksum: String,
        licenseExpiresAt: Date? = nil,
        licenseMachineId: String? = nil,
        licenseHMAC: String? = nil
    ) {
        self.launcherVersion = launcherVersion
        self.targetVersion = targetVersion
        self.patchedAt = patchedAt
        self.dylibChecksum = dylibChecksum
        self.configChecksum = configChecksum
        self.licenseExpiresAt = licenseExpiresAt
        self.licenseMachineId = licenseMachineId
        self.licenseHMAC = licenseHMAC
    }

    /// Compute HMAC-SHA256 of expiresAt + machineId using the embedded secret.
    /// This prevents users from simply editing the metadata JSON to bypass expiration.
    static func computeLicenseHMAC(expiresAt: Date, machineId: String) -> String {
        let payload = "\(Int(expiresAt.timeIntervalSince1970))|\(machineId)"
        let key = SymmetricKey(data: Data(licenseSecret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        return Data(signature).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Verify the stored HMAC matches the expected value.
    func isLicenseValid() -> Bool {
        guard let expiresAt = licenseExpiresAt,
              let machineId = licenseMachineId,
              let hmac = licenseHMAC else {
            return false
        }
        let expected = Self.computeLicenseHMAC(expiresAt: expiresAt, machineId: machineId)
        return hmac == expected && Date() <= expiresAt
    }

    /// Embedded license secret — compiled into binary, not in plaintext config.
    /// Change this value for each release to invalidate old forged metadata.
    private static let licenseSecret = "agpl-v3-secret-key-2026-do-not-share"
}

