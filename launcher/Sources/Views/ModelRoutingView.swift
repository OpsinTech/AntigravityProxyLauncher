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
                    llmRouterSection
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title2)
                    .foregroundStyle(.purple)
                Text("模型映射 (Model Routing)")
                    .font(.title2)
                    .bold()
            }
            Text("配置模型转译规则，将目标应用的 AI 接口请求无缝映射到第三方兼容提供商。")
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

            Text("勾选启用的目标厂家，并分别设定对应的 API 接入点（Endpoint）和密钥（API Key）。")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                ForEach($appState.modelRoutingConfig.providers) { $provider in
                    ProviderCard(provider: $provider)
                }
            }
        }
        .cardStyle(accent: .green)
    }

    // MARK: - Routing Rules Section

    private var routingRulesSection: some View {
        let currentRules = appState.modelRoutingConfig.routingRules

        return VStack(alignment: .leading, spacing: 16) {
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
                ForEach($appState.modelRoutingConfig.routingRules) { $rule in
                    let ruleID = $rule.wrappedValue.id
                    RoutingRuleRow(
                        rule: $rule,
                        allProviders: appState.modelRoutingConfig.providers,
                        onDelete: {
                            appState.modelRoutingConfig.routingRules.removeAll { $0.id == ruleID }
                        }
                    )
                    if ruleID != currentRules.last?.id {
                        Divider().opacity(0.5)
                    }
                }

                Button(action: {
                    let newRule = ModelRoutingConfig.RoutingRule(
                        sourceModelPattern: "",
                        sourceDisplayName: "新规则",
                        sourceType: "google",
                        targetProviderID: nil,
                        targetModel: nil,
                        enabled: true
                    )
                    appState.modelRoutingConfig.routingRules.append(newRule)
                }) {
                    HStack(spacing: 6) {
                        Spacer()
                        Image(systemName: "plus.circle")
                        Text("添加规则")
                        Spacer()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            .foregroundStyle(.secondary.opacity(0.5))
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .innerPanelStyle()
        }
        .padding(20)
        .cardStyle(accent: .orange)
    }

    // MARK: - LLMRouter Section

    private var llmRouterSection: some View {
        let hasLLMRouterRules = appState.modelRoutingConfig.routingRules.contains { $0.targetProviderID == LLMRouterProviderID }

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "shuffle")
                    .foregroundStyle(.purple)
                Text("LLM Router（关键词路由）")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.modelRoutingConfig.llmRouter?.enabled ?? false },
                    set: { isOn in
                        if isOn {
                            if appState.modelRoutingConfig.llmRouter == nil {
                                appState.modelRoutingConfig.llmRouter = ModelRoutingConfig.LLMRouterConfig()
                            }
                            appState.modelRoutingConfig.llmRouter?.enabled = true
                        } else {
                            appState.modelRoutingConfig.llmRouter?.enabled = false
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            Divider()

            if !hasLLMRouterRules {
                Text("在上方「模型路由映射规则」中将目标服务商选择为「LLM Router」后，请求将进入关键词路由子系统。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.modelRoutingConfig.llmRouter == nil || !appState.modelRoutingConfig.llmRouter!.enabled {
                Text("已有规则映射到 LLM Router，但未开启此功能。开启后将根据关键词匹配路由到不同模型。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("根据请求内容中的关键词，自动路由到不同的目标模型。未命中关键词时使用默认模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.modelRoutingConfig.llmRouter?.enabled == true {
                // Default model
                VStack(alignment: .leading, spacing: 8) {
                    Text("默认模型（未命中关键词时使用）")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Picker("默认厂家", selection: Binding(
                            get: { appState.modelRoutingConfig.llmRouter?.defaultProviderID ?? "" },
                            set: { newID in
                                appState.modelRoutingConfig.llmRouter?.defaultProviderID = newID
                                if let p = appState.modelRoutingConfig.providers.first(where: { $0.id == newID && $0.enabled }),
                                   !p.models.isEmpty {
                                    appState.modelRoutingConfig.llmRouter?.defaultModel = p.models[0]
                                } else {
                                    appState.modelRoutingConfig.llmRouter?.defaultModel = ""
                                }
                            }
                        )) {
                            Text("选择厂家").tag("")
                            ForEach(appState.modelRoutingConfig.providers.filter(\.enabled)) { p in
                                Text(p.name).tag(p.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)

                        let defaultPID = appState.modelRoutingConfig.llmRouter?.defaultProviderID ?? ""
                        if let provider = appState.modelRoutingConfig.providers.first(where: { $0.id == defaultPID && $0.enabled }) {
                            Picker("默认模型", selection: Binding(
                                get: { appState.modelRoutingConfig.llmRouter?.defaultModel ?? "" },
                                set: { appState.modelRoutingConfig.llmRouter?.defaultModel = $0 }
                            )) {
                                Text("选择模型").tag("")
                                ForEach(provider.models, id: \.self) { m in
                                    Text(m).tag(m)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        } else {
                            Spacer().frame(width: 200)
                        }
                    }
                }

                Divider()

                // Keyword rules
                VStack(alignment: .leading, spacing: 8) {
                    Text("关键词路由规则")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(.secondary)

                    // Header
                    HStack(spacing: 8) {
                        Text("关键词（逗号分隔）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 200, alignment: .leading)
                        Text("匹配模式")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text("目标厂家")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)
                        Text("目标模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 160, alignment: .leading)
                        Spacer().frame(width: 24)
                    }
                    .padding(.horizontal, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        let rulesBinding = Binding<[ModelRoutingConfig.LLMRouterRule]>(
                            get: { appState.modelRoutingConfig.llmRouter?.rules ?? [] },
                            set: { appState.modelRoutingConfig.llmRouter?.rules = $0 }
                        )
                        let currentRules = appState.modelRoutingConfig.llmRouter?.rules ?? []
                        ForEach(rulesBinding) { $rule in
                            let ruleID = $rule.wrappedValue.id
                            LLMRouterRuleRow(
                                rule: $rule,
                                allProviders: appState.modelRoutingConfig.providers,
                                onDelete: {
                                    appState.modelRoutingConfig.llmRouter?.rules.removeAll { $0.id == ruleID }
                                }
                            )
                            if ruleID != currentRules.last?.id {
                                Divider().opacity(0.3)
                            }
                        }

                        Button(action: {
                            appState.modelRoutingConfig.llmRouter?.rules.append(
                                ModelRoutingConfig.LLMRouterRule()
                            )
                        }) {
                            HStack(spacing: 6) {
                                Spacer()
                                Image(systemName: "plus.circle")
                                Text("添加关键词规则")
                                Spacer()
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                    .foregroundStyle(.secondary.opacity(0.5))
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    .innerPanelStyle()
                }
            }
        }
        .padding(20)
        .cardStyle(accent: .purple)
    }

    // MARK: - Control Section

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Button(action: {
                    appState.modelRoutingConfig = .default
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
        .cardStyle(accent: nil)
    }

    // MARK: - Helpers

    private func saveConfig() {
        appState.saveCurrentModelRoutingConfig()

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

    // Local model servers (ollama / vllm / llama.cpp) may not need an API key,
    // so only the endpoint is required to run a connectivity test.
    private var canTest: Bool { !provider.apiEndpoint.isEmpty }

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

                    HStack(spacing: 8) {
                        Text(" ")
                            .frame(width: 50, alignment: .leading)
                        Toggle("自动同步模型列表（启动时自动从接口获取）", isOn: Binding(
                            get: { provider.options["auto_models"] == "true" },
                            set: { newValue in
                                if newValue {
                                    provider.options["auto_models"] = "true"
                                } else {
                                    provider.options.removeValue(forKey: "auto_models")
                                }
                                clearTestResult()
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 11))
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
    private var modelsPath: String {
        if let apiPath = provider.options["api_path"], !apiPath.isEmpty {
            var parts = apiPath.split(separator: "/")
            if parts.count >= 2, parts.suffix(2).joined(separator: "/") == "chat/completions" {
                parts.removeLast(2)
                return "/" + parts.joined(separator: "/") + "/models"
            }
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

// MARK: - Source Models

private struct SourceModel: Identifiable {
    let pattern: String
    let displayName: String
    var id: String { pattern }
}

private let sourceModels: [SourceModel] = [
    .init(pattern: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
    .init(pattern: "claude-opus-4-6", displayName: "Claude Opus 4.6"),
    .init(pattern: "gpt-oss-120b", displayName: "GPT OSS 120B"),
]

private func sourceModelDisplayName(for pattern: String) -> String {
    sourceModels.first(where: { $0.pattern == pattern })?.displayName ?? pattern
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
                ForEach(sourceModels, id: \.pattern) { m in
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
                    if newID == LLMRouterProviderID {
                        rule.targetModel = nil
                    } else if let provider = allProviders.first(where: { $0.id == newID && $0.enabled }),
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
                Divider()
                Text("LLM Router").tag(LLMRouterProviderID)
            }
            .labelsHidden()
            .frame(width: 130)

            if rule.targetProviderID == LLMRouterProviderID {
                Text("关键词路由")
                    .font(.caption)
                    .foregroundStyle(.purple)
                    .frame(width: 170)
            } else if let pid = rule.targetProviderID,
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }
}

// MARK: - LLMRouter Rule Row

struct LLMRouterRuleRow: View {
    @Binding var rule: ModelRoutingConfig.LLMRouterRule
    let allProviders: [ModelRoutingConfig.ProviderConfig]
    @State private var keywordsText: String = ""
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Keywords input
            TextField("前端,React,Vue", text: $keywordsText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 200)
                .onChange(of: keywordsText) { newValue in
                    rule.keywords = newValue
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }

            // Match mode
            Picker("匹配模式", selection: $rule.matchMode) {
                Text("任一").tag("any")
                Text("全部").tag("all")
            }
            .labelsHidden()
            .frame(width: 90)

            // Target provider
            Picker("厂家", selection: $rule.targetProviderID) {
                Text("选择").tag("")
                ForEach(allProviders.filter(\.enabled)) { p in
                    Text(p.name).tag(p.id)
                }
                Divider()
                Text("Gemini（内置）").tag(GeminiBuiltinProviderID)
            }
            .labelsHidden()
            .frame(width: 120)

            // Target model
            if rule.targetProviderID == GeminiBuiltinProviderID {
                Picker("模型", selection: $rule.targetModel) {
                    Text("选择").tag("")
                    ForEach(GeminiBuiltinModels) { m in
                        Text(m.displayName).tag(m.id)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            } else if let provider = allProviders.first(where: { $0.id == rule.targetProviderID && $0.enabled }) {
                Picker("模型", selection: $rule.targetModel) {
                    Text("选择").tag("")
                    ForEach(provider.models, id: \.self) { m in
                        Text(m).tag(m)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            } else {
                Spacer().frame(width: 160)
            }

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
            }
            .iconButtonStyle()
            .help("删除此规则")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .onAppear {
            keywordsText = rule.keywords.joined(separator: ",")
        }
    }
}

// MARK: - Preview

#Preview {
    ModelRoutingView()
        .environmentObject(LauncherAppState())
}
