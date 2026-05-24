import AppKit
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: LauncherAppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            OverviewView()
                .tabItem {
                    Label("总览", systemImage: "gauge.with.needle")
                }
                .tag(LauncherTab.overview)

            ConfigView()
                .tabItem {
                    Label("配置", systemImage: "slider.horizontal.3")
                }
                .tag(LauncherTab.config)

            QuotaView()
                .tabItem {
                    Label("配额", systemImage: "chart.bar.doc.horizontal")
                }
                .tag(LauncherTab.quota)

            DiagnosticsView()
                .tabItem {
                    Label("诊断", systemImage: "stethoscope")
                }
                .tag(LauncherTab.diagnostics)

            RuntimeLogsView()
                .tabItem {
                    Label("运行日志", systemImage: "text.alignleft")
                }
                .tag(LauncherTab.runtimeLogs)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(LauncherTab.settings)
        }
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var appState: LauncherAppState
    @EnvironmentObject private var authViewModel: AuthViewModel
    @EnvironmentObject private var quotaViewModel: QuotaViewModel

    @State private var showCleanEnvironmentConfirm = false
    @State private var showClearLogsConfirm = false

    private var isOverviewTabActive: Bool {
        appState.selectedTab == .overview
    }

    private var statusColor: Color {
        switch appState.status {
        case .running, .patchedReady:
            return .green
        case .patching, .launching, .cleaning:
            return .blue
        case .targetAppInstalled, .patchedAppMissing, .patchedAppOutdated:
            return .orange
        case .targetAppMissing, .targetAppUnsupportedVersion, .error, .repairRequired:
            return .red
        }
    }

    @ViewBuilder
    private var releaseUpdateBanner: some View {
        if let info = appState.releaseUpdateInfo,
           info.isUpdateAvailable,
           !appState.isReleaseVersionIgnored(info.latestVersion) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.orange)
                    Text("发现 Launcher 新版本 \(info.latestVersion)")
                        .font(.headline)
                }

                Text("当前版本 \(info.currentVersion)，建议尽快更新以获得最新兼容规则与修复能力。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let notes = info.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 10) {
                    Button("打开下载页面") {
                        openReleaseDownloadPage()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button("检查更新") {
                        appState.checkLauncherUpdates(manual: true)
                    }
                    .buttonStyle(.bordered)

                    Button("忽略此版本") {
                        appState.ignoreCurrentReleaseUpdate()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange.opacity(0.32), lineWidth: 1)
            )
        }
    }

    private func openReleaseDownloadPage() {
        guard let urlString = appState.releaseUpdateInfo?.downloadURL,
              let url = URL(string: urlString) else {
            NSSound.beep()
            return
        }

        _ = NSWorkspace.shared.open(url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Antigravity Proxy Launcher")
                    .font(.largeTitle)
                    .bold()
                
                Spacer()
                
                Picker("", selection: $appState.selectedApp) {
                    ForEach(TargetApp.allCases) { app in
                        Text(app.displayName).tag(app)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                .disabled(appState.isRunningWorkflow)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text("当前状态: \(appState.status.title)")
                        .font(.headline)
                        .foregroundStyle(statusColor)
                }

                Text(appState.status.description)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18) // 对齐文字
            }

            releaseUpdateBanner

            HStack(alignment: .top, spacing: 16) {
                if let app = appState.appInfo {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Image(systemName: "app.badge.checkmark.fill")
                                .foregroundStyle(.blue)
                            Text("核心运行环境")
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 32) {
                                InfoItem(icon: "tag", title: "Bundle ID", value: app.bundleIdentifier)
                                InfoItem(icon: "number", title: "环境版本", value: app.version)
                            }
                            
                            Divider()
                                .opacity(0.5)

                            InfoItem(icon: "macwindow", title: "官方原版路径", value: app.appPath, isMono: true)
                            
                            // 检查破解版应用是否真实存在
                            let isPatchedAppExists = FileManager.default.fileExists(atPath: FileSystemPaths.patchedApp.path)
                            InfoItem(
                                icon: "lock.open",
                                title: "解锁版 App 路径",
                                value: isPatchedAppExists ? FileSystemPaths.patchedApp.path : "(未生成/已清理)",
                                valueColor: isPatchedAppExists ? .primary : .secondary,
                                isMono: true
                            )
                            
                            // Google 账户令牌文件路径
                            let tokenDirPath = FileSystemPaths.appSupportRoot.appendingPathComponent("oauth_tokens").path
                            let tokenFiles = try? FileManager.default.contentsOfDirectory(atPath: tokenDirPath)
                            let hasTokenFiles = tokenFiles?.contains { $0.hasSuffix(".json") } == true
                            
                            InfoItem(
                                icon: "key",
                                title: "当前授权环境目录",
                                value: hasTokenFiles ? tokenDirPath : "(未授权)",
                                valueColor: hasTokenFiles ? .primary : .secondary,
                                isMono: true
                            )
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.gray.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                    )
                }

                QuotaSummaryCard()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true) // 改为自适应高度，解决内容被挤压重叠的问题

            HStack(spacing: 12) {
                Button("刷新状态") {
                    appState.refresh()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(appState.isRunningWorkflow)

                if appState.status == .running {
                    Button("关闭修复版应用") {
                        appState.stopPatchedAppOnly()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(appState.isRunningWorkflow)

                    Button("修复应用") {
                        appState.patchOnly()
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.isRunningWorkflow)
                } else if appState.status == .patchedReady {
                    Button("启动应用") {
                        appState.launchPatchedAppOnly()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(appState.isRunningWorkflow)

                    Button("修复应用") {
                        appState.patchOnly()
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.isRunningWorkflow)
                } else {
                    Button("修复应用") {
                        appState.patchOnly()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.isRunningWorkflow)
                }

                Button("清理环境") {
                    showCleanEnvironmentConfirm = true
                }
                .disabled(appState.isRunningWorkflow)
                .confirmationDialog(
                    "确认清理环境",
                    isPresented: $showCleanEnvironmentConfirm,
                    titleVisibility: .visible
                ) {
                    Button("确认清理", role: .destructive) {
                        appState.cleanEnvironment()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将删除当前 \(appState.selectedApp.displayName) 的解锁版应用及相关配置文件。")
                }

                Button("清理日志") {
                    showClearLogsConfirm = true
                }
                .confirmationDialog(
                    "确认清理日志",
                    isPresented: $showClearLogsConfirm,
                    titleVisibility: .visible
                ) {
                    Button("确认清理", role: .destructive) {
                        appState.clearLogs()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将删除修复日志和运行日志文件，此操作不可恢复。")
                }

                Spacer(minLength: 8)
            }

            Divider()

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "checklist")
                            .foregroundStyle(.orange)
                        Text("流程进度")
                            .font(.headline)
                    }

                    ForEach(appState.workflowItems) { item in
                        HStack(alignment: .top, spacing: 10) {
                            workflowIcon(for: item.state)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline)
                                    .foregroundStyle(item.state == .pending ? .secondary : .primary)
                                if let detail = item.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.gray.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "terminal.fill")
                            .foregroundStyle(.gray)
                        Text("实时日志")
                            .font(.headline)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(appState.logLines.enumerated()), id: \.offset) { entry in
                                Text(entry.element)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(minHeight: 180)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.gray.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                )
            }
            .frame(height: 280)

            Spacer()
        }
        .padding(24)
        .onAppear {
            Task { @MainActor in
                appState.refresh()
                authViewModel.reloadState()
                quotaViewModel.loadCachedSnapshot(for: authViewModel.activeAccountId)
                quotaViewModel.selectAccount(authViewModel.activeAccountId ?? "")
                updateQuotaDiagnosticsDeferred()
            }
        }
        .onChange(of: authViewModel.activeAccountId) { newValue in
            guard isOverviewTabActive else { return }
            DispatchQueue.main.async {
                if let newValue, !newValue.isEmpty {
                    quotaViewModel.loadCachedSnapshot(for: newValue)
                    quotaViewModel.selectAccount(newValue)
                }
                updateQuotaDiagnosticsDeferred()
            }
        }
        .onChange(of: quotaViewModel.statusText) { _ in
            guard isOverviewTabActive else { return }
            updateQuotaDiagnosticsDeferred()
        }
    }

    private func updateQuotaDiagnosticsDeferred() {
        DispatchQueue.main.async {
            appState.updateQuotaDiagnostics(quotaViewModel.diagnosticsSummary)
        }
    }

    @ViewBuilder
    private func workflowIcon(for state: LaunchWorkflowStepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.gray.opacity(0.5))
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

private struct QuotaSummaryCard: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @EnvironmentObject private var quotaViewModel: QuotaViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "chart.pie.fill")
                    .foregroundStyle(.purple)
                Text("配额监控")
                    .font(.headline)

                Spacer()
                
                if quotaViewModel.uiStatus == .refreshing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.6)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                InfoItem(
                    icon: "network",
                    title: "连接状态",
                    value: quotaViewModel.statusText,
                    valueColor: statusColor
                )

                InfoItem(
                    icon: "person.circle",
                    title: "当前授权账户",
                    value: authViewModel.activeAccount?.email ?? "未登录",
                    valueColor: authViewModel.activeAccount == nil ? .secondary : .primary
                )

                HStack(spacing: 32) {
                    InfoItem(icon: "arrow.triangle.2.circlepath", title: "上次刷新", value: quotaViewModel.lastRefreshText)
                    InfoItem(
                        icon: quotaViewModel.isPolling ? "bolt.fill" : "bolt.slash.fill",
                        title: "后台刷新",
                        value: quotaViewModel.isPolling ? "已开启" : "已关闭",
                        valueColor: quotaViewModel.isPolling ? .green : .secondary
                    )
                }

                if let nextRefresh = quotaViewModel.nextAutoRefreshTime {
                    InfoItem(icon: "clock.arrow.circlepath", title: "下次自动刷新", value: nextRefresh, valueColor: .secondary)
                }
            }

            if !quotaViewModel.lowestModels.isEmpty {
                Divider()
                    .opacity(0.5)
                    .padding(.vertical, 2)

                Text("资源余量预警 (最低配额)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(quotaViewModel.lowestModels) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(.caption)
                                .fontWeight(.medium)
                            if model.isExhausted {
                                Text("已耗尽")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        Text("\(Int(model.remainingPercentage))%")
                            .font(.caption)
                            .foregroundStyle(model.isExhausted ? .red : .primary)
                    }
                }
            }

            if let error = quotaViewModel.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch quotaViewModel.uiStatus {
        case .notLoggedIn:
            return .secondary
        case .hasCachedNotRefreshed:
            return .blue
        case .refreshing:
            return .orange
        case .refreshSuccess:
            return .green
        case .reauthRequired:
            return .red
        case .refreshFailed:
            return .red
        }
    }
}

private struct InfoItem: View {
    let icon: String
    let title: String
    let value: String
    var valueColor: Color = .primary
    var isMono: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .top)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(isMono ? .system(.caption, design: .monospaced) : .subheadline)
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value) // 鼠标悬停显示完整路径
            }
        }
    }
}

