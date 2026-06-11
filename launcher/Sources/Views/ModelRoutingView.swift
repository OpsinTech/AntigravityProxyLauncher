import SwiftUI

struct ModelRoutingView: View {
    @EnvironmentObject private var appState: LauncherAppState
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                globalToggleSection
                
                if appState.proxyConfigDraft.mitm?.modelRoutingEnabled ?? true {
                    providerSection
                    routingRulesSection
                }
                
                controlSection
                Spacer()
            }
            .padding(24)
        }
        .onAppear {
            appState.loadProxyConfigIfNeeded()
            appState.loadModelRoutingConfigIfNeeded()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title2)
                    .foregroundStyle(.purple)
                Text("模型映射 (Model Routing)")
                    .font(.title2)
                    .bold()
            }
            Text("配置模型转译规则，将目标应用的 AI 接口（如 Anthropic/Claude、Google Gemini）请求无缝映射到第三方兼容提供商。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 32)
        }
    }

    // MARK: - Global Toggle

    private var globalToggleSection: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("启用全局模型重定向")
                    .font(.headline)
                Text("控制底层拦截注入层是否将 AI 请求转发至本地转译网关（需配合保存配置与重新“修复并启动”生效）。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { appState.proxyConfigDraft.mitm?.modelRoutingEnabled ?? true },
                set: { newValue in
                    if appState.proxyConfigDraft.mitm != nil {
                        appState.proxyConfigDraft.mitm?.modelRoutingEnabled = newValue
                    } else {
                        appState.proxyConfigDraft.mitm = .init(modelRoutingEnabled: newValue)
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.purple.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.badge.person.crop")
                    .foregroundStyle(.green)
                Text("接口厂家配置")
                    .font(.headline)
            }
            Divider()

            Text("勾选启用的目标厂家，并分别设定对应的 API 接入点（Endpoint）和密钥（API Key）。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                ForEach($appState.modelRoutingConfigDraft.providers) { $provider in
                    ProviderCard(provider: $provider)
                }
            }
        }
        .padding(20)
        .background(Color.gray.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Routing Rules Section

    private var routingRulesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.orange)
                Text("模型路由映射规则")
                    .font(.headline)
            }
            Divider()

            Text("为应用内置的源模型选择映射的目标服务商和模型。如果规则处于启用状态但服务商被禁用，则规则不会生效。")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Header labels for alignment
            HStack(spacing: 8) {
                Spacer()
                    .frame(width: 40) // Space matching the toggle
                Text("源模型匹配名称")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)
                Spacer()
                    .frame(width: 20)
                Text("目标服务商")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                Text("映射目标模型")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.secondary)
                    .frame(width: 170, alignment: .leading)
                Spacer()
            }
            .padding(.horizontal, 8)

            VStack(spacing: 8) {
                ForEach($appState.modelRoutingConfigDraft.routingRules) { $rule in
                    RoutingRuleRow(rule: $rule, allProviders: appState.modelRoutingConfigDraft.providers)
                    if rule.id != appState.modelRoutingConfigDraft.routingRules.last?.id {
                        Divider()
                            .opacity(0.5)
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
        .padding(20)
        .background(Color.gray.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Control Section

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Button("恢复默认") {
                    appState.modelRoutingConfigDraft = ModelRoutingConfig.default
                    statusMessage = "已恢复默认映射规则，请点击保存并应用配置。"
                }

                Button(action: {
                    saveConfig()
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("保存并应用配置")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                Spacer()

                if let message = statusMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
                if let error = errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }

            Divider()
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.secondary)
                Text("模型映射配置文件: \(ModelRoutingService().configPath())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .background(Color.gray.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func saveConfig() {
        appState.saveProxyConfig()
        appState.saveModelRoutingConfig()

        if let err = appState.configErrorMessage ?? appState.modelRoutingErrorMessage {
            errorMessage = "保存失败: \(err)"
            statusMessage = nil
        } else {
            ProxyManager.shared.restartProxy()
            statusMessage = "配置已保存，代理已自动重启生效。"
            errorMessage = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                statusMessage = nil
            }
        }
    }
}

// MARK: - Provider Card

struct ProviderCard: View {
    @Binding var provider: ModelRoutingConfig.ProviderConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(provider.name)
                    .font(.headline)
                    .foregroundStyle(provider.enabled ? .primary : .secondary)
                Spacer()
                Toggle("", isOn: $provider.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if provider.enabled {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text("接入点")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .leading)
                        TextField("api.provider.com", text: $provider.apiEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }

                    HStack(spacing: 8) {
                        Text("API Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .leading)
                        SecureField("sk-xxxx", text: $provider.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Spacer()
                    .frame(height: 56) // Ensure height matches card height to prevent jumping
            }
        }
        .padding(16)
        .background(provider.enabled ? Color.green.opacity(0.04) : Color.gray.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(provider.enabled ? Color.green.opacity(0.2) : Color.gray.opacity(0.1), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: provider.enabled)
    }
}

// MARK: - Routing Rule Row

struct RoutingRuleRow: View {
    @Binding var rule: ModelRoutingConfig.RoutingRule
    let allProviders: [ModelRoutingConfig.ProviderConfig]

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $rule.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .frame(width: 40)

            HStack(spacing: 8) {
                Text(rule.sourceDisplayName)
                    .font(.body)
                    .frame(width: 140, alignment: .leading)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(width: 20)

                Picker("厂家", selection: Binding(
                    get: { rule.targetProviderID ?? "" },
                    set: { newID in
                        rule.targetProviderID = newID.isEmpty ? nil : newID
                        if let provider = allProviders.first(where: { $0.id == newID }), !provider.models.isEmpty {
                            rule.targetModel = provider.models[0]
                        } else {
                            rule.targetModel = nil
                        }
                    }
                )) {
                    Text("选择厂家").tag("")
                    ForEach(allProviders) { p in
                        Text(p.enabled ? p.name : "\(p.name) (已禁用)").tag(p.id)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .disabled(!rule.enabled)

                if let pid = rule.targetProviderID,
                   let provider = allProviders.first(where: { $0.id == pid }) {
                    Picker("模型", selection: Binding(
                        get: { rule.targetModel ?? "" },
                        set: { rule.targetModel = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("选择模型").tag("")
                        ForEach(provider.models, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .disabled(!rule.enabled)
                } else {
                    Spacer()
                        .frame(width: 170)
                }
                Spacer()
            }
            .opacity(rule.enabled ? 1.0 : 0.5)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }
}

// MARK: - Preview

#Preview {
    ModelRoutingView()
        .environmentObject(LauncherAppState())
}
