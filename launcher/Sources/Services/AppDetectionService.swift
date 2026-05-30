import Foundation

struct AppDetectionService {
    func detectInstalledTargetApp() -> AppInfo? {
        if FileSystemPaths.activeApp.targetType == .cliBinary {
            return detectCLIBinary()
        }

        let appURL = FileSystemPaths.targetApp
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            return nil
        }

        let infoPlist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: infoPlist) as? [String: Any] else {
            return nil
        }

        let bundleID = dict["CFBundleIdentifier"] as? String ?? ""
        let version = dict["CFBundleShortVersionString"] as? String
            ?? (dict["CFBundleVersion"] as? String ?? "unknown")
        let executable = dict["CFBundleExecutable"] as? String ?? "Electron"
        let executableRelativePath = "Contents/MacOS/\(executable)"
        let executablePath = appURL.appendingPathComponent(executableRelativePath).path
        let architectures = detectArchitectures(executablePath: executablePath)

        return AppInfo(
            appPath: appURL.path,
            bundleIdentifier: bundleID,
            version: version,
            executableRelativePath: executableRelativePath,
            architectures: architectures
        )
    }

    private func detectCLIBinary() -> AppInfo? {
        let symlinkURL = FileSystemPaths.targetApp
        let fm = FileManager.default
        guard fm.fileExists(atPath: symlinkURL.path) else {
            return nil
        }

        // Resolve to the actual binary, bypassing the wrapper if already patched.
        // The wrapper injects DYLD_INSERT_LIBRARIES which hangs if proxy is not running.
        let binaryURL: URL
        let isSymlink = (try? symlinkURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        if isSymlink {
            let resolved = symlinkURL.resolvingSymlinksInPath()
            // If the symlink points to our wrapper, use the real binary directly
            let realBinary = resolved.deletingLastPathComponent()
                .appendingPathComponent(FileSystemPaths.activeApp.cliRealBinaryName)
            if fm.fileExists(atPath: realBinary.path) {
                binaryURL = realBinary
            } else {
                // Fallback to the original backup if it exists
                let backupURL = URL(fileURLWithPath: symlinkURL.path + ".original")
                if fm.fileExists(atPath: backupURL.path) {
                    binaryURL = backupURL
                } else {
                    binaryURL = symlinkURL
                }
            }
        } else {
            binaryURL = symlinkURL
        }

        guard fm.isExecutableFile(atPath: binaryURL.path) else {
            return nil
        }

        let version = detectCLIVersion(binaryURL: binaryURL)
        let architectures = detectArchitectures(executablePath: binaryURL.path)

        return AppInfo(
            appPath: symlinkURL.path,
            bundleIdentifier: "",
            version: version,
            executableRelativePath: "",
            architectures: architectures
        )
    }

    private func detectCLIVersion(binaryURL: URL) -> String {
        let args = FileSystemPaths.activeApp.cliVersionArgs
        do {
            let result = try CommandRunner.run(binaryURL.path, args)
            let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // agy --version outputs the version on its own line; grab first non-empty line
            let versionLine = output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
                ?? output
            return versionLine.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "unknown"
        }
    }

    private func detectArchitectures(executablePath: String) -> [String] {
        do {
            let result = try CommandRunner.run("/usr/bin/lipo", ["-archs", executablePath])
            let values = result.stdout
                .split(whereSeparator: \ .isWhitespace)
                .map(String.init)
            return values
        } catch {
            return []
        }
    }
}
