import SwiftUI
import AppKit
import Darwin

@main
struct AntigravityProxyLauncherApp: App {
    @StateObject private var appState = LauncherAppState()
    @StateObject private var authViewModel = AuthViewModel()
    @StateObject private var quotaViewModel = QuotaViewModel()

    init() {
        do {
            try FileSystemPaths.ensureRuntimeDirectoriesExist()
        } catch {
            LauncherLogger.warn("Failed to ensure runtime directories: \(error.localizedDescription)")
        }

        switch LauncherCLICommandParser.parse(from: CommandLine.arguments) {
        case .doctor:
            Darwin.exit(LauncherDoctor().run())
        case .exportDiagnostics:
            Darwin.exit(LauncherDoctor().exportDiagnosticsFromCLI())
        case .verifyPatched:
            Darwin.exit(LauncherDoctor().verifyPatchedAppFromCLI())
        case .patchAndLaunch:
            Darwin.exit(LauncherDoctor().patchAndLaunchFromCLI())
        case .help:
            print(LauncherCLICommandParser.helpText)
            Darwin.exit(0)
        case .unknown(let arg):
            print("未知参数: \(arg)")
            print(LauncherCLICommandParser.helpText)
            Darwin.exit(2)
        case .none:
            let bundleIdentifier = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if bundleIdentifier.isEmpty {
#if DEBUG
                print("当前进程缺少主 Bundle Identifier，已切换为开发模式继续启动 GUI。")
                LauncherLogger.warn("Missing bundle identifier in DEBUG run. Continue GUI bootstrap for local development.")
#else
                print("当前进程缺少主 Bundle Identifier，已跳过 GUI 启动。")
                print("请使用 .app 方式启动 GUI，或改用 CLI 诊断命令。")
                print(LauncherCLICommandParser.helpText)
                Darwin.exit(2)
#endif
            } else {
                LauncherLogger.info("GUI bootstrap with bundle identifier: \(bundleIdentifier)")
            }

            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            break
        }

        LauncherLogger.info("Launcher started in GUI mode. If no terminal output appears, check the app window in Dock/桌面。")
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(appState)
                .environmentObject(authViewModel)
                .environmentObject(quotaViewModel)
                .frame(minWidth: 820, minHeight: 560)
        }

        MenuBarExtra {
            menuBarContent
                .environmentObject(appState)
                .environmentObject(authViewModel)
                .environmentObject(quotaViewModel)
        } label: {
            menuBarIcon
        }
    }

    @ViewBuilder
    private var menuBarContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.status.title)
                .font(.headline)
            Text(appState.selectedApp.displayName)

            Divider()

            if appState.status == .running {
                Button("关闭 \(appState.selectedApp.displayName)") {
                    appState.stopPatchedAppOnly()
                }
            } else {
                Button("启动 \(appState.selectedApp.displayName)") {
                    appState.launchPatchedAppOnly()
                }
                .disabled(appState.status == .patching || appState.status == .launching)
            }

            if appState.status != .patching && appState.status != .launching {
                Button("修复 \(appState.selectedApp.displayName)") {
                    appState.patchOnly()
                }
            }

            Divider()

            Button("显示主窗口") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                if let window = NSApplication.shared.windows.first(where: { $0.title.contains("Antigravity") }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }

            Divider()

            Button("退出 Launcher") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 180)
    }

    private var menuBarIcon: some View {
        let color: Color = {
            switch appState.status {
            case .running: return .green
            case .patching, .launching, .cleaning: return .blue
            case .patchedReady: return .yellow
            case .error, .targetAppMissing, .targetAppUnsupportedVersion, .repairRequired: return .red
            case .targetAppInstalled, .patchedAppMissing, .patchedAppOutdated: return .orange
            }
        }()

        return Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }
}
