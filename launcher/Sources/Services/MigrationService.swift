import Foundation

struct MigrationService {
    func migrateSandboxData() throws {
        switch FileSystemPaths.activeApp {
        case .antigravity, .antigravityIDE:
            break
        case .gemini:
            return
        }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let destination = home.appendingPathComponent("Library/Application Support/\(FileSystemPaths.activeApp.displayName)")
        let sources = findPossibleSandboxSources(baseHome: home)

        guard !sources.isEmpty else {
            return
        }

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for source in sources {
            _ = try CommandRunner.run(
                "/usr/bin/rsync",
                ["-av", "--update", source.path + "/", destination.path + "/"]
            )
        }

        resetTCCPermissions()
    }

    private func findPossibleSandboxSources(baseHome home: URL) -> [URL] {
        let fm = FileManager.default
        let containersRoot = home.appendingPathComponent("Library/Containers", isDirectory: true)
        guard let containerFolders = try? fm.contentsOfDirectory(
            at: containersRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [URL] = []
        let activeApp = FileSystemPaths.activeApp
        for container in containerFolders {
            let name = container.lastPathComponent.lowercased()
            let matches: Bool = {
                switch activeApp {
                case .antigravity:
                    return name == "antigravity" || name.hasSuffix(".antigravity")
                case .antigravityIDE:
                    return name.contains("antigravity") && name.contains("ide")
                case .gemini:
                    return false
                }
            }()
            if matches {
                let appSupport = container
                    .appendingPathComponent("Data/Library/Application Support/\(activeApp.displayName)", isDirectory: true)
                if fm.fileExists(atPath: appSupport.path) {
                    result.append(appSupport)
                }
            }
        }
        return result
    }

    private func resetTCCPermissions() {
        let identities: [String] = {
            switch FileSystemPaths.activeApp {
            case .antigravity:
                return [
                    "Antigravity",
                    "com.google.antigravity",
                    "com.apple.antigravity",
                    "com.google.antigravity.helper",
                    "com.google.antigravity.helper.GPU",
                    "com.google.antigravity.helper.Plugin",
                    "com.google.antigravity.helper.Renderer",
                    "Antigravity_Unlocked"
                ]
            case .antigravityIDE:
                return [
                    "Antigravity IDE",
                    "com.google.antigravity-ide",
                    "com.google.antigravity-ide.helper",
                    "Antigravity IDE_Unlocked"
                ]
            case .gemini:
                return [
                    "Gemini",
                    "com.google.GeminiMacOS",
                    "Gemini_Unlocked"
                ]
            }
        }()

        for identity in identities {
            _ = try? CommandRunner.run("/usr/bin/tccutil", ["reset", "All", identity])
        }
    }
}
