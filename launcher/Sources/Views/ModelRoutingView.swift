import SwiftUI

struct ModelRoutingView: View {
    @EnvironmentObject private var appState: LauncherAppState
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var isRestarting = false

    private var isModelRoutingEnabled: Bool {
        appState.proxyConfigDraft.mitm?.modelRoutingEnabled ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection

                if isModelRoutingEnabled {
                    providerSection
                    routingRulesSection
                    controlSection
                } else {
                    disabledBanner
                }
                Spacer()
            }
            .padding(24)
        }
        .onAppear {
            appState.loadProxyConfigIfNeeded()
            appState.loadModelRoutingConfigIfNeeded()
        }
    }

    private var disabledBanner: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 40)
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("模型映射未启用")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("请先在「代理设置」中开启「模型映射」开关，然后再配置映射规则。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("前往代理设置") {
                appState.selectedTab = .proxySettings
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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

            Text("配置需要转译的源模型，选择目标服务商和模型。规则存在即生效，删除即停止映射。")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Header labels
            HStack(spacing: 8) {
                Text("源模型匹配名称")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)
                Spacer().frame(width: 20)
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
                Spacer().frame(width: 24)
            }
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 8) {
                ForEach($appState.modelRoutingConfigDraft.routingRules) { $rule in
                    RoutingRuleRow(rule: $rule, allProviders: appState.modelRoutingConfigDraft.providers,
                                   onDelete: {
                        appState.modelRoutingConfigDraft.routingRules.removeAll { $0.id == rule.id }
                    })
                    if rule.id != appState.modelRoutingConfigDraft.routingRules.last?.id {
                        Divider().opacity(0.5)
                    }
                }

                Button(action: {
                    let newRule = ModelRoutingConfig.RoutingRule(
                        sourceModelPattern: "",
                        sourceDisplayName: "新规则",
                        targetProviderID: nil,
                        targetModel: nil,
                        enabled: true
                    )
                    appState.modelRoutingConfigDraft.routingRules.append(newRule)
                }) {
                    ButtonLabel(icon: "plus.circle.fill", text: "添加规则")
                }
                .secondaryActionStyle()
                .padding(.top, 4)
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
                Button(action: {
                    appState.modelRoutingConfigDraft = ModelRoutingConfig.default
                    statusMessage = "已恢复默认映射规则，请点击保存并应用配置。"
                }) {
                    ButtonLabel(icon: "arrow.counterclockwise", text: "恢复默认")
                }
                .secondaryActionStyle()

                Button(action: { saveConfig() }) {
                    if isRestarting {
                        HStack(spacing: 3) {
                            ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                            Text("重启代理中...").font(.system(size: 11, weight: .bold))
                        }
                    } else {
                        ButtonLabel(icon: "square.and.arrow.down", text: "保存并应用")
                    }
                }
                .primaryActionStyle()
                .disabled(isRestarting)

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
        appState.saveModelRoutingConfig()

        if let err = appState.modelRoutingErrorMessage {
            errorMessage = "保存失败: \(err)"
            statusMessage = nil
            return
        }

        errorMessage = nil
        statusMessage = nil
        isRestarting = true

        DispatchQueue.global(qos: .userInitiated).async {
            ProxyManager.shared.restartProxy()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let ok = ProxyManager.shared.healthCheck()
                isRestarting = false
                if ok {
                    statusMessage = "路由规则已保存，代理已重启生效。"
                } else {
                    errorMessage = "代理重启后健康检查失败，请检查端口 18081。"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    statusMessage = nil
                    errorMessage = nil
                }
            }
        }
    }
}

// MARK: - Provider Card

struct ProviderCard: View {
    @Binding var provider: ModelRoutingConfig.ProviderConfig

    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testOK = false
    private let modelService = ModelListService()

    private var canTest: Bool { !provider.apiEndpoint.isEmpty && !provider.apiKey.isEmpty }

    private var providerWebsite: URL? {
        switch provider.id {
        case "deepseek":  return URL(string: "https://platform.deepseek.com/api_keys")
        case "ofox":      return URL(string: "https://app.ofox.ai/")
        case "codebuddy": return URL(string: "https://www.codebuddy.cn/")
        default:          return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(provider.name)
                    .font(.headline)
                    .foregroundStyle(provider.enabled ? .primary : .secondary)
                if let url = providerWebsite {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .iconButtonStyle()
                    .help("打开 \(provider.name) 官网")
                }
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
                            .onChange(of: provider.apiEndpoint) { _ in clearTestResult() }
                    }

                    HStack(spacing: 8) {
                        Text("API Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .leading)
                        SecureField("sk-xxxx", text: $provider.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .onChange(of: provider.apiKey) { _ in clearTestResult() }
                    }

                    HStack(spacing: 8) {
                        Text("API 路径")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .leading)
                        TextField("/v1/chat/completions", text: Binding(
                            get: { provider.options["api_path"] ?? "" },
                            set: { newValue in
                                if newValue.isEmpty {
                                    provider.options.removeValue(forKey: "api_path")
                                } else {
                                    provider.options["api_path"] = newValue
                                }
                                clearTestResult()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    }

                    // Test connection + fetch models
                    HStack(spacing: 8) {
                        Text(" ")
                            .frame(width: 50, alignment: .leading)

                        Button(action: { testConnection() }) {
                            if isTesting {
                                HStack(spacing: 3) {
                                    ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                                    Text("测试中...").font(.system(size: 11, weight: .bold))
                                }
                            } else {
                                ButtonLabel(icon: "play.circle", text: "测试连接")
                            }
                        }
                        .primaryActionStyle()
                        .disabled(!canTest || isTesting)
                        .help("验证 API 连通性并获取可用模型列表")
                    }

                    // Result
                    if let result = testResult {
                        HStack(spacing: 6) {
                            Image(systemName: testOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(testOK ? .green : .red)
                            Text(result)
                                .font(.system(size: 11))
                                .foregroundStyle(testOK ? .green : .red)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Spacer().frame(height: 80)
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

    private func clearTestResult() {
        testResult = nil
        testOK = false
    }

    /// Derive the models listing path from the chat completions api_path.
    /// e.g. "/v2/chat/completions" → "/v2/models", "/v1/chat/completions" → "/v1/models"
    private var modelsPath: String {
        if let apiPath = provider.options["api_path"], !apiPath.isEmpty {
            // Replace the last path component ("chat/completions") with "models"
            var parts = apiPath.split(separator: "/")
            if parts.count >= 2, parts.suffix(2).joined(separator: "/") == "chat/completions" {
                parts.removeLast(2)
                return "/" + parts.joined(separator: "/") + "/models"
            }
            // Fallback: just replace the last segment
            if parts.count >= 1 {
                parts.removeLast()
                return "/" + parts.joined(separator: "/") + "/models"
            }
        }
        return "/v1/models"
    }

    private var authHeader: String {
        provider.options["auth_header"] ?? "Authorization"
    }

    private var authPrefix: String {
        provider.options["auth_prefix"] ?? "Bearer "
    }

    private var extraHeaders: [String: String] {
        guard let raw = provider.options["extra_headers"], !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let headers = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return headers
    }

    private func testConnection() {
        guard canTest else { return }
        isTesting = true
        testResult = nil
        Task {
            do {
                let models = try await modelService.fetchModels(
                    endpoint: provider.apiEndpoint,
                    apiKey: provider.apiKey,
                    modelsPath: modelsPath,
                    authHeader: authHeader,
                    authPrefix: authPrefix,
                    extraHeaders: extraHeaders
                )
                await MainActor.run {
                    provider.models = models
                    testOK = true
                    testResult = "连接成功，已获取 \(models.count) 个模型"
                    isTesting = false
                }
            } catch let error as ModelListService.ModelListError {
                // If models endpoint returns 404, probe with a real chat request
                if case .httpError(404) = error {
                    let apiPath = provider.options["api_path"] ?? "/v1/chat/completions"
                    let result = await modelService.probeEndpoint(
                        endpoint: provider.apiEndpoint,
                        apiKey: provider.apiKey,
                        apiPath: apiPath,
                        authHeader: authHeader,
                        authPrefix: authPrefix,
                        extraHeaders: extraHeaders
                    )
                    await MainActor.run {
                        testOK = result.ok
                        if result.ok {
                            let modelCount = provider.models.count
                            if modelCount > 0 {
                                testResult = "连通性正常，已有 \(modelCount) 个预置模型。模型列表接口不可用(404)"
                            } else {
                                testResult = "连通性正常，但模型列表接口不可用(404)，请手动填写模型名称"
                            }
                        } else {
                            testResult = result.message
                        }
                        isTesting = false
                    }
                } else {
                    await MainActor.run {
                        testOK = false
                        testResult = "连接失败: \(error.localizedDescription)"
                        isTesting = false
                    }
                }
            } catch {
                await MainActor.run {
                    testOK = false
                    testResult = "连接失败: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}

// MARK: - Routing Rule Row


// MARK: - Source Models

private struct SourceModel: Identifiable {
    let pattern: String
    let displayName: String
    var id: String { pattern }
}

private enum SourceModels {
    static let all: [SourceModel] = [
        .init(pattern: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        .init(pattern: "claude-opus-4-6", displayName: "Claude Opus 4.6"),
        .init(pattern: "gpt-oss-120b", displayName: "GPT OSS 120B"),
    ]
}

private func sourceModelDisplayName(for pattern: String) -> String {
    SourceModels.all.first(where: { $0.pattern == pattern })?.displayName ?? pattern
}

struct RoutingRuleRow: View {
    @Binding var rule: ModelRoutingConfig.RoutingRule
    let allProviders: [ModelRoutingConfig.ProviderConfig]
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("源模型", selection: Binding(
                get: { rule.sourceModelPattern },
                set: { newValue in
                    rule.sourceModelPattern = newValue
                    rule.sourceDisplayName = sourceModelDisplayName(for: newValue)
                }
            )) {
                ForEach(SourceModels.all, id: \.pattern) { m in
                    Text(m.displayName).tag(m.pattern)
                }
            }
            .labelsHidden()
            .frame(width: 140)

            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 20)

            Picker("厂家", selection: Binding(
                get: {
                    if let pid = rule.targetProviderID,
                       let p = allProviders.first(where: { $0.id == pid }),
                       !p.enabled { return "" }
                    return rule.targetProviderID ?? ""
                },
                set: { newID in
                    rule.targetProviderID = newID.isEmpty ? nil : newID
                    if let provider = allProviders.first(where: { $0.id == newID && $0.enabled }),
                       !provider.models.isEmpty {
                        rule.targetModel = provider.models[0]
                    } else {
                        rule.targetModel = nil
                    }
                }
            )) {
                Text("选择厂家").tag("")
                ForEach(allProviders.filter(\.enabled)) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            if let pid = rule.targetProviderID,
               let provider = allProviders.first(where: { $0.id == pid && $0.enabled }) {
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
            } else {
                Spacer().frame(width: 170)
            }

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
            }
            .iconButtonStyle()
            .help("删除此规则")
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
