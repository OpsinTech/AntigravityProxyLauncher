import Foundation

struct LauncherDoctor {
    private let detection = AppDetectionService()
    private let verifier = PatchVerificationService()
    private let patch = PatchService()
    private let migration = MigrationService()
    private let launch = LaunchService()
    private let settingsService = AppSettingsService()

    func run() -> Int32 {
        print("=== Antigravity Proxy Launcher Doctor ===")
        print("时间: \(Date())")
        print("目标路径: \(FileSystemPaths.targetApp.path)")
        print("修复路径: \(FileSystemPaths.patchedApp.path)")

        guard let app = detection.detectInstalledTargetApp() else {
            let failure = LauncherFailure(code: .targetAppMissing, message: "未检测到原版 App")
            print("错误: \(failure.formatted)")
            print("建议: 确保 \(FileSystemPaths.targetApp.path) 存在")
            return failure.codeValue
        }

        print("状态: 检测到原版 App")
        if app.bundleIdentifier.isEmpty {
            print("Bundle ID: N/A (CLI binary)")
        } else {
            print("Bundle ID: \(app.bundleIdentifier)")
        }
        print("Version: \(app.version)")
        if app.executableRelativePath.isEmpty {
            print("Executable: (CLI binary, no bundle)")
        } else {
            print("Executable: \(app.executableRelativePath)")
        }
        print("Architectures: \(app.architectures.joined(separator: ", "))")

        let dylibSource = FileSystemPaths.runtimeDylibCandidates.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
        if let dylibSource {
            print("Dylib 资源: 已找到 (\(dylibSource.path))")
        } else {
            print("Dylib 资源: 缺失")
            let failure = LauncherFailure(code: .runtimeAssetMissing, message: "libAntigravityTun.dylib 缺失")
            print("错误: \(failure.formatted)")
            print("建议: 运行 legacy_scripts/compile_without_xcode.sh，或放置到 launcher/Resources、legacy_scripts")
            return failure.codeValue
        }

        print("Doctor 检查完成: 可继续执行 GUI 修复流程。")
        return LauncherErrorCode.success.rawValue
    }


    func verifyPatchedAppFromCLI() -> Int32 {
        do {
            try verifier.verifyPatchedResult()
            print("patched app 验证通过")
            return LauncherErrorCode.success.rawValue
        } catch {
            let failure = LauncherErrorMapper.map(error)
            print("patched app 验证失败: \(failure.formatted)")
            return failure.codeValue
        }
    }

    func patchAndLaunchFromCLI() -> Int32 {
        print("=== Antigravity Proxy Launcher CLI Patch Workflow ===")

        let doctorCode = run()
        if doctorCode != 0 {
            print("中止: doctor 检查未通过。")
            return doctorCode
        }

        do {
            print("[1/4] 迁移数据")
            try migration.migrateSandboxData()

            print("[2/4] 执行 patch")
            try patch.preparePatchedBundle(onProgress: { message in
                print("  - \(message)")
            })

            print("[3/4] 验证 patch")
            try verifier.verifyPatchedResult()

            print("[4/4] 启动修复版")
            let _ = try runAsyncBlocking {
                let settings = try? settingsService.load()
                try await launch.launchPatchedApp(settings: settings)
            }

            print("CLI 全流程执行成功")
            return LauncherErrorCode.success.rawValue
        } catch {
            let failure = LauncherErrorMapper.map(error)
            print("CLI 全流程执行失败: \(failure.formatted)")
            return failure.codeValue
        }
    }

    private func runAsyncBlocking<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<T, Error>?

        Task {
            do {
                outcome = .success(try await operation())
            } catch {
                outcome = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return try outcome!.get()
    }
}
