import Foundation

struct SigningService {
    func preflight() throws {
        let requiredTools = [
            "/usr/bin/codesign",
            "/usr/bin/xattr",
            "/usr/libexec/PlistBuddy"
        ]

        for tool in requiredTools {
            if !FileManager.default.isExecutableFile(atPath: tool) {
                throw CommandRunnerError.executableNotFound(tool)
            }
        }

        // Verify ad-hoc signing capability (codesign --sign - should work without a certificate)
        // Create a tiny temp file and attempt to sign it to catch common issues early
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity_signing_preflight_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test_sign")
        try "test".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        do {
            _ = try CommandRunner.run("/usr/bin/codesign", [
                "--force", "--sign", "-", testFile.path
            ])
        } catch {
            throw CommandRunnerError.commandFailed(
                tool: "codesign",
                message: "Ad-hoc 签名能力不可用，请确认 Xcode Command Line Tools 已安装。\(error.localizedDescription)"
            )
        }
    }

    func resignBundleInsideOut(
        at appURL: URL,
        entitlementsURL: URL,
        onProgress: ((String) -> Void)? = nil
    ) throws {
        try preflight()

        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let mainExecutable = try locateMainExecutable(appURL: appURL)
        let nestedBundles = try collectNestedCodeBundles(in: contentsURL)
            .sorted { $0.path.count > $1.path.count }
        let standaloneFiles = try collectStandaloneCodeFiles(
            in: contentsURL,
            excludingBundles: nestedBundles,
            excludingMainExecutable: mainExecutable
        )
            .sorted { $0.path.count > $1.path.count }

        onProgress?("Inside-out signing started")
        onProgress?("Nested bundles=\(nestedBundles.count), standalone files=\(standaloneFiles.count)")

        for (index, bundle) in nestedBundles.enumerated() {
            onProgress?("Signing bundle [\(index + 1)/\(nestedBundles.count)]: \(bundle.path)")
            try removeSignatureIfExists(at: bundle)
            try sign(path: bundle.path, entitlementsPath: entitlementsURL.path)
        }

        for (index, file) in standaloneFiles.enumerated() {
            onProgress?("Signing file [\(index + 1)/\(standaloneFiles.count)]: \(file.path)")
            try removeSignatureIfExists(at: file)
            try sign(path: file.path, entitlementsPath: entitlementsURL.path)
        }

        onProgress?("Signing main executable: \(mainExecutable.path)")
        try removeSignatureIfExists(at: mainExecutable)
        try sign(path: mainExecutable.path, entitlementsPath: entitlementsURL.path)

        onProgress?("Signing app bundle: \(appURL.path)")
        try removeSignatureIfExists(at: appURL)
        try sign(path: appURL.path, entitlementsPath: entitlementsURL.path)
        onProgress?("Inside-out signing completed")
    }

    private func collectNestedCodeBundles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let nestedBundleExtensions = Set(["framework", "app", "xpc", "appex"])
        var bundles: [URL] = []

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }

            let ext = url.pathExtension.lowercased()
            if nestedBundleExtensions.contains(ext) {
                bundles.append(url)
                enumerator.skipDescendants()
            }
        }
        return bundles
    }

    private func collectStandaloneCodeFiles(
        in root: URL,
        excludingBundles: [URL],
        excludingMainExecutable: URL
    ) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
            guard values.isRegularFile == true else { continue }
            if url.path == excludingMainExecutable.path { continue }

            if excludingBundles.contains(where: { url.path.hasPrefix($0.path + "/") }) {
                continue
            }

            let isDylib = url.pathExtension.lowercased() == "dylib"
            let noExtensionExecutable = url.pathExtension.isEmpty && (values.isExecutable == true)
            if (isDylib || noExtensionExecutable) && isMachO(url.path) {
                files.append(url)
            }
        }

        return files
    }

    private func locateMainExecutable(appURL: URL) throws -> URL {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let dict = NSDictionary(contentsOf: infoURL) as? [String: Any]
        let executableName = dict?["CFBundleExecutable"] as? String ?? "Electron"
        return appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
    }

    private func isMachO(_ path: String) -> Bool {
        do {
            let result = try CommandRunner.run("/usr/bin/file", [path])
            return result.stdout.contains("Mach-O")
        } catch {
            return false
        }
    }

    private func removeSignatureIfExists(at url: URL) throws {
        do {
            _ = try CommandRunner.run("/usr/bin/codesign", ["--remove-signature", url.path])
        } catch {
            // 某些文件本来没有签名，忽略即可。
        }
    }

    private func sign(path: String, entitlementsPath: String) throws {
        _ = try CommandRunner.run(
            "/usr/bin/codesign",
            ["--force", "--options", "runtime", "--sign", "-", "--entitlements", entitlementsPath, path]
        )
    }

    /// Re-sign a single standalone Mach-O binary (not an .app bundle).
    func signSingleBinary(at binaryURL: URL, entitlementsURL: URL) throws {
        try preflight()

        // Remove existing signature (ignore failure if binary has none)
        _ = try? CommandRunner.run("/usr/bin/codesign", ["--remove-signature", binaryURL.path])

        _ = try CommandRunner.run(
            "/usr/bin/codesign",
            [
                "--force",
                "--options", "runtime",
                "--sign", "-",
                "--entitlements", entitlementsURL.path,
                binaryURL.path
            ]
        )
    }
}
