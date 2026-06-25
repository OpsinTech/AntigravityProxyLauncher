import Foundation

enum PatchedAppHealth {
    case missing
    case ready
    case outdated
    case repairRequired(String)
}

struct PatchedAppHealthService {
    func evaluate(targetVersion: String) -> PatchedAppHealth {
        if FileSystemPaths.activeApp.targetType == .cliBinary {
            return evaluateCLI(targetVersion: targetVersion)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: FileSystemPaths.patchedApp.path) else {
            return .missing
        }

        guard let metadata = latestMetadata() else {
            return .repairRequired("未找到 patch 元数据，请重新修复。")
        }

        if metadata.targetVersion != targetVersion {
            return .outdated
        }

        let dylib = FileSystemPaths.patchedApp
            .appendingPathComponent("Contents/Resources/libAntigravityTun.dylib")

        guard fm.fileExists(atPath: dylib.path) else {
            return .repairRequired("修复包缺少 dylib，请重新修复。")
        }

        return .ready
    }

    private func evaluateCLI(targetVersion: String) -> PatchedAppHealth {
        let fm = FileManager.default
        let wrapper = FileSystemPaths.patchedCLIWrapper
        let realBinary = FileSystemPaths.patchedCLIRealBinary
        let dylib = FileSystemPaths.patchedCLIDylib

        guard fm.fileExists(atPath: wrapper.path) else { return .missing }

        guard let metadata = latestMetadata() else {
            return .repairRequired("未找到 patch 元数据，请重新修复。")
        }

        if metadata.targetVersion != targetVersion {
            return .outdated
        }

        guard fm.fileExists(atPath: realBinary.path),
              fm.fileExists(atPath: dylib.path) else {
            return .repairRequired("修复目录缺少关键资源，请重新修复。")
        }

        guard fm.isExecutableFile(atPath: wrapper.path) else {
            return .repairRequired("wrapper 脚本不可执行，请重新修复。")
        }

        return .ready
    }

    private func latestMetadata() -> PatchMetadata? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: FileSystemPaths.metadataRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates = files.filter {
            $0.lastPathComponent.hasPrefix("launcher_patch_metadata_") && $0.pathExtension == "json"
        }

        let decoder = JSONDecoder()
        var latest: PatchMetadata?

        for url in candidates {
            guard
                let data = try? Data(contentsOf: url),
                let current = try? decoder.decode(PatchMetadata.self, from: data)
            else {
                continue
            }

            if let existed = latest {
                if current.patchedAt > existed.patchedAt {
                    latest = current
                }
            } else {
                latest = current
            }
        }

        return latest
    }
}
