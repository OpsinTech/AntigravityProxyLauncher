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

            let hideDock = AntigravityProxyLauncherApp.loadHideDockIconSetting()
            if hideDock {
                NSApplication.shared.setActivationPolicy(.accessory)
                LauncherLogger.info("Dock icon hidden (setting from file)")
            } else {
                NSApplication.shared.setActivationPolicy(.regular)
            }
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
            ForEach(TargetApp.allCases) { app in
                let status = appState.allAppStatuses[app] ?? MenuBarAppStatus(app: app, isInstalled: false, isRunning: false, isPatched: false)

                if status.isPatched || status.isInstalled || status.isRunning {
                    Menu {
                        if status.isRunning {
                            Button {
                                appState.stopSpecificApp(app)
                            } label: {
                                Label("关闭", systemImage: "stop.circle")
                            }
                        }
                        if status.isPatched && !status.isRunning {
                            Button {
                                appState.launchSpecificApp(app)
                            } label: {
                                Label("启动", systemImage: "play.circle")
                            }
                        }
                        if status.isInstalled {
                            Button {
                                appState.patchSpecificApp(app)
                            } label: {
                                Label("修复", systemImage: "wrench")
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: app.iconName)
                                .frame(width: 18)
                            Text(app.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(status.statusText)
                                .font(.caption)
                                .foregroundStyle(colorForStatus(status))
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: app.iconName)
                            .frame(width: 18)
                            .foregroundStyle(.gray)
                        Text(app.displayName)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(status.statusText)
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
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
        .frame(minWidth: 240)
    }

    private func colorForStatus(_ status: MenuBarAppStatus) -> Color {
        if status.isRunning { return .green }
        if status.isPatched { return .yellow }
        if status.isInstalled { return .secondary }
        return .gray
    }

    private var menuBarIcon: some View {
        let icon = menuBarResizedIcon()
        return Image(nsImage: icon)
    }

    private func menuBarResizedIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        if let appIcon = NSApp.applicationIconImage,
           let rep = NSBitmapImageRep(
               bitmapDataPlanes: nil,
               pixelsWide: Int(size.width),
               pixelsHigh: Int(size.height),
               bitsPerSample: 8,
               samplesPerPixel: 4,
               hasAlpha: true,
               isPlanar: false,
               colorSpaceName: .deviceRGB,
               bytesPerRow: 0,
               bitsPerPixel: 32
           ) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            appIcon.draw(in: NSRect(origin: .zero, size: size),
                         from: .zero,
                         operation: .copy,
                         fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            let resized = NSImage(size: size)
            resized.addRepresentation(rep)
            return resized
        }
        return NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil) ?? NSImage()
    }

    private static func loadHideDockIconSetting() -> Bool {
        let fileURL = FileSystemPaths.settingsFile
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (json["hideDockIcon"] as? Bool) ?? false
    }
}
