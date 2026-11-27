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

    /// 逐个目标（Antigravity / IDE / Gemini / agy）跑一遍健康检查。
    /// 对应「切换 tab 就提示需要修复」这类问题：单个目标看起来正常，
    /// 但换到另一个目标才暴露，必须一次性全查。
    func verifyAllTargetsFromCLI() -> Int32 {
        let saved = FileSystemPaths.activeApp
        defer { FileSystemPaths.activeApp = saved }

        var failed: [String] = []
        let health = PatchedAppHealthService()

        for app in TargetApp.allCases {
            FileSystemPaths.activeApp = app
            // 目标 App 根本没装：跳过，不算失败（否则每次全量检查都会红一片）。
            guard let info = AppDetectionService().detectInstalledTargetApp() else {
                let name = app.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)
                print("\(name) 未安装（已跳过）")
                continue
            }
            let version = info.version
            let verdict: String
            switch health.evaluate(targetVersion: version) {
            case .missing:
                verdict = "已安装但未修复 (missing)"
                failed.append(app.rawValue)
            case .ready:
                verdict = "就绪 (ready)"
            case .outdated:
                verdict = "版本过期 (outdated)"
                failed.append(app.rawValue)
            case .repairRequired(let message):
                verdict = "需要修复: \(message)"
                failed.append(app.rawValue)
            }
            let name = app.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)
            print("\(name) v\(version.padding(toLength: 18, withPad: " ", startingAt: 0)) \(verdict)")
        }

        FileSystemPaths.activeApp = saved
        if failed.isEmpty {
            print("全部目标验证通过")
            return LauncherErrorCode.success.rawValue
        }
        print("以下目标未通过: \(failed.joined(separator: ", "))")
        return LauncherErrorCode.verifyFailed.rawValue
    }

    /// 按磁盘上的最新配置重启网关（等价于设置页「重启网关」）。
    /// 托管模式下会重建 LaunchAgent plist，因此上游代理变更是真正生效的。
    ///
    /// 注意：`ProxyManager.restartProxy` 的收尾工作在 main queue 上，
    /// 而 CLI 进程默认没有 main run loop —— 必须 dispatchMain() 才会执行。
    func restartGatewayFromCLI() -> Int32 {
        DispatchQueue.global(qos: .userInitiated).async {
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                ProxyManager.shared.restartProxy(reason: "CLI --restart-gateway") {
                    finished.signal()
                }
            }

            let waitResult = finished.wait(timeout: .now() + 30)
            guard waitResult != .timedOut else {
                print("重启网关超时")
                Darwin.exit(LauncherErrorCode.launchFailed.rawValue)
            }

            // 进程起来到真正 bind 有一小段间隔，稍等再探端口。
            Thread.sleep(forTimeInterval: 2)
            if MitmProxyService.isPortListening() {
                print("网关已重启，127.0.0.1:\(MitmProxyService.port) 监听正常")
                Darwin.exit(LauncherErrorCode.success.rawValue)
            }
            print("网关重启后未监听 127.0.0.1:\(MitmProxyService.port)")
            Darwin.exit(LauncherErrorCode.launchFailed.rawValue)
        }
        dispatchMain()
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
