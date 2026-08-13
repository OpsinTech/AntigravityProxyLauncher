import Foundation

struct PatchMetadata: Codable, Equatable {
    let launcherVersion: String
    let targetVersion: String
    let patchedAt: Date
    let dylibChecksum: String
    let configChecksum: String

    enum CodingKeys: String, CodingKey {
        case launcherVersion = "launcher_version"
        case targetVersion = "target_version"
        case patchedAt = "patched_at"
        case dylibChecksum = "dylib_checksum"
        case configChecksum = "config_checksum"
    }

    init(
        launcherVersion: String,
        targetVersion: String,
        patchedAt: Date,
        dylibChecksum: String,
        configChecksum: String
    ) {
        self.launcherVersion = launcherVersion
        self.targetVersion = targetVersion
        self.patchedAt = patchedAt
        self.dylibChecksum = dylibChecksum
        self.configChecksum = configChecksum
    }
}
