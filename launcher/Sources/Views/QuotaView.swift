import SwiftUI

struct QuotaView: View {
    @EnvironmentObject private var appState: LauncherAppState
    @EnvironmentObject private var authViewModel: AuthViewModel
    @EnvironmentObject private var quotaViewModel: QuotaViewModel

    @State private var showingLogoutConfirm = false
    @State private var selectedAccountPickerId: String = ""

    private var pollingBinding: Binding<Bool> {
        Binding(
            get: { quotaViewModel.isPolling },
            set: { enabled in
                if enabled {
                    let interval = max(5, appState.settingsDraft.quotaPollingIntervalSeconds)
                    quotaViewModel.startPolling(intervalSeconds: TimeInterval(interval))
                } else {
                    quotaViewModel.stopPolling()
                }
            }
        )
    }

    private var isQuotaTabActive: Bool {
        appState.selectedTab == .quota
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection

            if authViewModel.accounts.isEmpty {
                if authViewModel.isBusy {
                    VStack(spacing: 16) {
                        Spacer()
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(authViewModel.statusMessage ?? "登录中...")
                            .foregroundStyle(.secondary)
                        Button("取消登录") {
                            authViewModel.cancelLogin()
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    unauthenticatedEmptyState
                }
            } else if quotaViewModel.uiStatus == .notLoggedIn && !authViewModel.accounts.isEmpty {
                emptyStateView(message: "请先刷新配额数据", actionTitle: "刷新当前账户") {
                    quotaViewModel.refreshCurrentAccount()
                }
            } else if case .refreshFailed = quotaViewModel.uiStatus, quotaViewModel.snapshot == nil {
                emptyStateView(message: quotaViewModel.errorMessage ?? "刷新失败，请重试", actionTitle: "重试") {
                    quotaViewModel.refreshCurrentAccount()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // 卡片 1: 账号选择与控制面板
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .foregroundStyle(.blue)
                                Text("活跃账户与同步控制")
                                    .font(.headline)
                            }
                            
                            Divider()

                            accountSelector

                            if authViewModel.isBusy {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                    Text(authViewModel.statusMessage ?? "处理中...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    
                                    if authViewModel.loginFlowState != .idle && authViewModel.loginFlowState != .success {
                                        Button("取消") {
                                            authViewModel.cancelLogin()
                                        }
                                        .font(.caption)
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.blue)
                                    }
                                }
                                .padding(.leading, 112)
                            } else if let msg = authViewModel.errorMessage, !msg.isEmpty {
                                Text(msg)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(.leading, 112)
                            }

                            controlBar
                        }
                        .padding(20)
                        .background(Color.gray.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                        )

                        // 卡片 2: 快照信息、过滤条件与模型列表
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(.purple)
                                Text("配额快照与资源分配")
                                    .font(.headline)
                            }
                            
                            Divider()

                            if quotaViewModel.snapshot != nil {
                                snapshotInfoSection
                                filterBar
                                modelListSection
                            } else if quotaViewModel.selectedAccountHasCachedSnapshot {
                                snapshotInfoSection
                            } else {
                                Text("尚未生成有效快照。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(20)
                        .background(Color.gray.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                        )
                    }
                }
            }

            Spacer()
        }
        .padding(24)
        .onAppear {
            DispatchQueue.main.async {
                authViewModel.reloadState()
                let initialAccountId = authViewModel.activeAccountId ?? ""
                selectedAccountPickerId = initialAccountId
                quotaViewModel.loadCachedSnapshot(for: initialAccountId.isEmpty ? nil : initialAccountId)
                if !initialAccountId.isEmpty {
                    quotaViewModel.selectAccount(initialAccountId)
                }
                syncPollingWithSettingsDeferred()
                updateQuotaDiagnosticsDeferred()
            }
        }
        .onChange(of: authViewModel.activeAccountId) { newValue in
            guard isQuotaTabActive else { return }
            DispatchQueue.main.async {
                let normalized = newValue ?? ""
                if selectedAccountPickerId != normalized {
                    selectedAccountPickerId = normalized
                }
                if !normalized.isEmpty {
                    quotaViewModel.selectAccount(normalized)
                }
                syncPollingWithSettingsDeferred()
                updateQuotaDiagnosticsDeferred()
            }
        }
        .onChange(of: selectedAccountPickerId) { newId in
            guard isQuotaTabActive else { return }
            DispatchQueue.main.async {
                guard !newId.isEmpty else {
                    return
                }
                if authViewModel.activeAccountId != newId {
                    authViewModel.switchActiveAccount(to: newId)
                }
                quotaViewModel.selectAccount(newId)
                syncPollingWithSettingsDeferred()
            }
        }
        .onChange(of: appState.settingsDraft.quotaAutoRefreshEnabled) { enabled in
            guard isQuotaTabActive else { return }
            _ = enabled
            syncPollingWithSettingsDeferred()
        }
        .onChange(of: appState.settingsDraft.quotaPollingIntervalSeconds) { seconds in
            guard isQuotaTabActive else { return }
            _ = seconds
            syncPollingWithSettingsDeferred()
        }
        .onChange(of: quotaViewModel.uiStatus) { _ in
            guard isQuotaTabActive else { return }
            updateQuotaDiagnosticsDeferred()
        }
    }

    private func updateQuotaDiagnosticsDeferred() {
        DispatchQueue.main.async {
            appState.updateQuotaDiagnostics(quotaViewModel.diagnosticsSummary)
        }
    }

    private func syncPollingWithSettingsDeferred() {
        DispatchQueue.main.async {
            syncPollingWithSettings()
        }
    }

    private func syncPollingWithSettings() {
        let enabled = appState.settingsDraft.quotaAutoRefreshEnabled
        let interval = TimeInterval(max(5, appState.settingsDraft.quotaPollingIntervalSeconds))
        let hasActiveAccount = authViewModel.activeAccount != nil

        guard enabled, hasActiveAccount else {
            if quotaViewModel.isPolling {
                quotaViewModel.stopPolling()
            }
            return
        }

        if quotaViewModel.isPolling {
            if quotaViewModel.pollingIntervalSeconds == interval {
                return
            }
            quotaViewModel.stopPolling()
        }

        quotaViewModel.startPolling(intervalSeconds: interval)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "chart.pie.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
                Text("配额与账户管理")
                    .font(.title2)
                    .bold()
            }

            Text("查看多账户配额状态，支持后台静默轮询更新与一键免密调度。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 32)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var unauthenticatedEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(needsOAuthSetup ? "缺少 OAuth 客户端配置，请先完成配置" : "暂无账户，请先登录 Google 账户")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if needsOAuthSetup {
                Text("请前往「设置 > Google OAuth 登录」填写 Client ID / Client Secret，并点击“保存并应用参数”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            if let msg = authViewModel.errorMessage, !msg.isEmpty {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            HStack(spacing: 10) {
                if needsOAuthSetup {
                    Button("去设置") {
                        appState.selectedTab = .settings
                    }
                    .buttonStyle(.borderedProminent)

                    Button("已保存，去登录") {
                        authViewModel.login()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("去登录") {
                        authViewModel.login()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var needsOAuthSetup: Bool {
        if !OAuthConstants.hasValidClientCredential {
            return true
        }

        let message = authViewModel.errorMessage?.lowercased() ?? ""
        return message.contains("invalid_client") || message.contains("客户端配置无效")
    }

    private var accountSelector: some View {
        HStack(spacing: 12) {
            Text("当前账户")
                .frame(width: 100, alignment: .leading)

            Picker("", selection: $selectedAccountPickerId) {
                Text("未选择账户").tag("")
                ForEach(authViewModel.accounts) { account in
                    Text(account.email).tag(account.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300)
            .disabled(authViewModel.isBusy)
            
            HStack(spacing: 8) {
                Button {
                    authViewModel.login()
                } label: {
                    Image(systemName: "person.badge.plus")
                    Text("添加账户")
                }
                .buttonStyle(.bordered)
                .disabled(authViewModel.isBusy)

                if authViewModel.activeAccountId != nil {
                    Button(role: .destructive) {
                        showingLogoutConfirm = true
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("退出登录")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(authViewModel.isBusy)
                    .alert("确认退出登录？", isPresented: $showingLogoutConfirm) {
                        Button("取消", role: .cancel) { }
                        Button("确认退出", role: .destructive) {
                            authViewModel.logout()
                        }
                    } message: {
                        Text("退出后将移除该账号的本地授权信息，需重新登录才能继续获取服务配额。")
                    }
                }
            }

            Spacer()
        }
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button("刷新当前账户") {
                    quotaViewModel.refreshCurrentAccount()
                }
                .buttonStyle(.borderedProminent)
                .disabled(quotaViewModel.uiStatus == .refreshing || authViewModel.accounts.isEmpty)

                Button("刷新全部账户") {
                    quotaViewModel.refreshAllAccounts()
                }
                .buttonStyle(.bordered)
                .disabled(quotaViewModel.uiStatus == .refreshing || authViewModel.accounts.isEmpty)

                Spacer()

                Toggle(quotaViewModel.isPolling ? "停止自动刷新" : "开启自动刷新", isOn: pollingBinding)
                .toggleStyle(.button)
                .disabled(authViewModel.accounts.isEmpty)
            }

            // 刷新状态指示器
            if quotaViewModel.uiStatus == .refreshing {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                    
                    Text("正在刷新配额数据...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: quotaViewModel.uiStatus)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            // 左侧固定标签列，与其他页保持相同列宽
            Text("排序依据")
                .frame(width: 100, alignment: .leading)

            Picker("", selection: $quotaViewModel.sortOption) {
                ForEach(QuotaModelSortOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300)

            // 过滤条件左对齐分布
            HStack(spacing: 8) {
                Text("过滤条件")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                
                Toggle(isOn: $quotaViewModel.showExhaustedOnly) {
                    Text("仅显示已耗尽")
                }
                .toggleStyle(.checkbox)
                .disabled(authViewModel.accounts.isEmpty)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var snapshotInfoSection: some View {
        if let snapshot = quotaViewModel.snapshot {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("账户: \(snapshot.userEmail)")
                        Text("Tier: \(snapshot.tier)")
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("上次刷新: \(quotaViewModel.lastRefreshText)")
                        if let nextRefresh = quotaViewModel.nextAutoRefreshTime {
                            Text("下次刷新: \(nextRefresh)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Label("\(snapshot.models.count) 个模型", systemImage: "cube.box")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if quotaViewModel.exhaustedModelsExist {
                        Label("存在耗尽", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(.subheadline)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )
        } else if quotaViewModel.selectedAccountId != nil && !quotaViewModel.selectedAccountHasCachedSnapshot {
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
                Text("暂无快照，可立即刷新当前账户")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.blue.opacity(0.15), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var modelListSection: some View {
        VStack(spacing: 0) {
            if quotaViewModel.displayedModels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    Text("所有模型配额充足")
                        .font(.headline)
                    if quotaViewModel.showExhaustedOnly {
                        Text("筛选条件无匹配结果")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(32)
            } else {
                VStack(spacing: 12) {
                    ForEach(quotaViewModel.displayedModels) { model in
                        VStack(spacing: 16) {
                            ModelQuotaRow(model: model)
                            Divider()
                        }
                    }
                }
                .padding(.top, 0)
            }
        }
    }

    @ViewBuilder
    private func emptyStateView(message: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !actionTitle.isEmpty {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ModelQuotaRow: View {
    let model: ModelQuotaInfo

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.headline)

                    if model.isExhausted {
                        Text("已耗尽")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Text(model.modelId)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("重置于 \(formattedResetTime)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(model.remainingPercentage))%")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(model.isExhausted ? .red : percentageColor)

                ProgressView(value: model.remainingPercentage, total: 100)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                    .tint(progressColor)
            }
        }
        .padding(.vertical, 4)
    }

    private var formattedResetTime: String {
        guard let reset = model.resetTime else {
            return "待接口返回"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: reset)
    }

    private var percentageColor: Color {
        if model.remainingPercentage < 20 {
            return .red
        } else if model.remainingPercentage < 50 {
            return .orange
        } else {
            return .green
        }
    }

    private var progressColor: Color {
        if model.remainingPercentage < 20 {
            return .red
        } else if model.remainingPercentage < 50 {
            return .orange
        } else {
            return .green
        }
    }
}
