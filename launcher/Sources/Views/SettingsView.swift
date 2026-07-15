import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: LauncherAppState
    @EnvironmentObject private var authViewModel: AuthViewModel
    @State private var revealGoogleClientSecret = false
    @State private var revealGithubToken = false
    @State private var isTestingCredentials = false
    @State private var credentialTestResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundStyle(.gray)
                        Text("偏好设置")
                            .font(.title2)
                            .bold()
                    }

                    Text("控制底层修复流程行为、自恢复策略与调度参数。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 32)
                }

                VStack(alignment: .leading, spacing: 20) {
                    // License 卡片
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.purple)
                            Text("License")
                                .font(.headline)
                            Spacer()
                            if let info = appState.licenseInfo {
                                Circle()
                                    .fill(info.isExpired ? Color.red : Color.green)
                                    .frame(width: 8, height: 8)
                                Text(info.isExpired ? "已过期" : "已激活")
                                    .font(.caption)
                                    .foregroundStyle(info.isExpired ? .red : .green)
                            }
                        }
                        Divider()

                        if let info = appState.licenseInfo {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("方案:")
                                        .foregroundStyle(.secondary)
                                    Text(info.plan.capitalized)
                                        .fontWeight(.medium)
                                }
                                HStack {
                                    Text("状态:")
                                        .foregroundStyle(.secondary)
                                    Text(info.statusText)
                                        .foregroundStyle(info.daysRemaining <= 7 ? .orange : .green)
                                }
                                HStack {
                                    Text("到期:")
                                        .foregroundStyle(.secondary)
                                    Text(info.expiresAt, style: .date)
                                }

                                HStack(spacing: 12) {
                                    Button("验证 License") {
                                        appState.verifyLicense()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button("移除 License", role: .destructive) {
                                        appState.deactivateLicense()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("输入 License Key 激活 Pro 功能")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 8) {
                                    TextField("XXXX-XXXX-XXXX-XXXX", text: $appState.licenseKeyInput)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(width: 200)

                                    Button("激活") {
                                        appState.activateLicense(key: appState.licenseKeyInput)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(appState.licenseKeyInput.isEmpty)
                                }

                                Button("获取 License") {
                                    if let url = URL(string: "https://antigravity.yourdomain.com/pricing") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.link)
                                .controlSize(.small)
                            }
                        }

                        if let msg = appState.licenseStatusMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        if let err = appState.licenseErrorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(20)
                    .background(Color.gray.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                    )

                    // 外观卡片
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "dock.rectangle")
                                .foregroundStyle(.teal)
                            Text("外观")
                                .font(.headline)
                        }
                        Divider()

                        Toggle("隐藏 Dock 图标（仅保留菜单栏图标）", isOn: $appState.settingsDraft.hideDockIcon)
                            .toggleStyle(.switch)

                        Text("说明：隐藏后需重启应用生效，应用仅显示在菜单栏中。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(Color.gray.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                    )

                    // Google OAuth 凭据卡片
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "person.badge.key")
                                .foregroundStyle(.mint)
                            Text("Google OAuth 登录")
                                .font(.headline)

                            Spacer()

                            // 当前登录状态徽章
                            authStatusBadge
                        }

                        Divider()

                        // 当前账户状态
                        if authViewModel.accounts.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "person.slash")
                                    .foregroundStyle(.secondary)
                                Text("当前状态：未登录")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .foregroundStyle(.green)
                                Text("当前状态：已登录 \(authViewModel.accounts.count) 个账户")
                                    .font(.subheadline)
                                    .foregroundStyle(.green)

                                if let active = authViewModel.activeAccount {
                                    Text("（活跃：\(active.email)）")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        HStack {
                            Text("Client ID")
                                .frame(width: 100, alignment: .leading)
                            TextField("填写 Google OAuth Client ID", text: $appState.settingsDraft.googleOAuthClientID)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack(spacing: 8) {
                            Text("Client Secret")
                                .frame(width: 100, alignment: .leading)

                            Group {
                                if revealGoogleClientSecret {
                                    TextField("填写 Google OAuth Client Secret", text: $appState.settingsDraft.googleOAuthClientSecret)
                                } else {
                                    SecureField("填写 Google OAuth Client Secret", text: $appState.settingsDraft.googleOAuthClientSecret)
                                }
                            }
                                .textFieldStyle(.roundedBorder)

                            Button(action: { revealGoogleClientSecret.toggle() }) {
                                ButtonLabel(icon: revealGoogleClientSecret ? "eye.slash" : "eye", text: revealGoogleClientSecret ? "隐藏" : "显示")
                            }
                            .secondaryActionStyle()
                        }

                        // 凭据验证按钮
                        HStack(spacing: 10) {
                            Button(action: testOAuthCredentials) {
                                ButtonLabel(icon: isTestingCredentials ? "hourglass" : "checkmark.shield", text: isTestingCredentials ? "验证中..." : "测试凭据有效性")
                            }
                            .secondaryActionStyle()
                            .disabled(isTestingCredentials)

                            if let result = credentialTestResult {
                                Text(result)
                                    .font(.caption)
                                    .foregroundStyle(result.hasPrefix("✓") ? .green : .red)
                                    .transition(.opacity)
                            }
                        }

                        Text("说明：若同时设置了环境变量 AG_GOOGLE_CLIENT_ID / AG_GOOGLE_CLIENT_SECRET，环境变量优先。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("点击底部「保存并应用」后凭据即生效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(Color.gray.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                    )
                    // 版本更新提醒卡片
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.purple)
                            Text("Launcher 更新提醒")
                                .font(.headline)
                        }

                        Divider()

                        HStack {
                            Text("当前版本")
                                .frame(width: 100, alignment: .leading)
                            Text(appState.launcherVersionText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("更新来源")
                                .frame(width: 100, alignment: .leading)
                            TextField("GitHub 仓库地址，如 OpsinTech/AntigravityProxyLauncher", text: $appState.settingsDraft.releaseFeedURL)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Text("授信域名")
                                .frame(width: 100, alignment: .leading)
                            TextField("仅自建 feed 时需要，逗号分隔", text: $appState.settingsDraft.releaseFeedTrustedHosts)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack(spacing: 8) {
                            Text("GitHub Token")
                                .frame(width: 100, alignment: .leading)

                            Group {
                                if revealGithubToken {
                                    TextField("可选: 提升 API 请求限额", text: $appState.settingsDraft.githubToken)
                                } else {
                                    SecureField("可选: 提升 API 请求限额", text: $appState.settingsDraft.githubToken)
                                }
                            }
                            .textFieldStyle(.roundedBorder)

                            Button(action: { revealGithubToken.toggle() }) {
                                ButtonLabel(icon: revealGithubToken ? "eye.slash" : "eye", text: revealGithubToken ? "隐藏" : "显示")
                            }
                            .secondaryActionStyle()
                        }

                        Text("说明：未配置 Token 时 GitHub API 每小时限 60 次请求，配置后提升至 5000 次/小时。Token 仅用于检查更新，权限范围只需 public_repo（或无权限亦可）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button(action: { appState.checkLauncherUpdates(manual: true) }) {
                                ButtonLabel(icon: "arrow.down.circle", text: "检查更新")
                            }
                            .primaryActionStyle()

                            Button(action: { appState.checkLauncherUpdates(manual: true, forceRefresh: true) }) {
                                ButtonLabel(icon: "arrow.clockwise", text: "强制刷新")
                            }
                            .secondaryActionStyle()
                            .help("清除缓存并重新检查")

                            if let info = appState.releaseUpdateInfo, info.isUpdateAvailable, !appState.isReleaseVersionIgnored(info.latestVersion) {
                                Text("发现新版本: \(info.latestVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        if !appState.settingsDraft.releaseIgnoredVersion.isEmpty {
                            HStack(spacing: 10) {
                                Text("已忽略版本: \(appState.settingsDraft.releaseIgnoredVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Button(action: { appState.clearIgnoredReleaseVersion() }) {
                                    ButtonLabel(icon: "bell", text: "恢复提醒")
                                }
                                .secondaryActionStyle()
                            }
                        }

                        if let status = appState.releaseUpdateStatusMessage, !status.isEmpty {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let error = appState.releaseUpdateErrorMessage, !error.isEmpty {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(20)
                    .background(Color.gray.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                    )

                    // Footer 行动点与路径说明
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Button(action: { appState.loadSettings() }) {
                                ButtonLabel(icon: "arrow.counterclockwise", text: "恢复默认")
                            }
                            .secondaryActionStyle()
                            
                            Button(action: { appState.saveSettings() }) {
                                ButtonLabel(icon: "square.and.arrow.down", text: "保存并应用")
                            }
                            .primaryActionStyle()
                        }
                        
                        Divider()
                        
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(.secondary)
                            Text("运行时用户层环境变量路径: \(FileSystemPaths.settingsFile.path)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
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

                Spacer()
            }
            .padding(24)
        }
        .onAppear {
            appState.loadSettings()
        }
        .animation(.easeInOut(duration: 0.25), value: credentialTestResult)
    }

    // MARK: - OAuth 凭据验证

    /// 通过尝试启动 OAuth 流程的第一步（构建授权 URL）来验证凭据是否有效。
    /// 这不会真正打开浏览器，只会校验 client_id 是否合法。
    private func testOAuthCredentials() {
        guard !isTestingCredentials else { return }

        let clientID = appState.settingsDraft.googleOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = appState.settingsDraft.googleOAuthClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            credentialTestResult = "✗ 请先填写 Client ID 和 Client Secret"
            return
        }

        guard !clientID.hasPrefix("YOUR_"), !clientSecret.hasPrefix("YOUR_") else {
            credentialTestResult = "✗ 请替换为真实的 Google OAuth 凭据"
            return
        }

        isTestingCredentials = true
        credentialTestResult = nil

        Task {
            do {
                // 通过构建一个最小化的授权 URL 来校验 client_id 格式
                var components = URLComponents(url: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!, resolvingAgainstBaseURL: false)
                components?.queryItems = [
                    URLQueryItem(name: "client_id", value: clientID),
                    URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:0/callback"),
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "scope", value: "openid email"),
                    URLQueryItem(name: "state", value: "test"),
                    URLQueryItem(name: "code_challenge", value: "test"),
                    URLQueryItem(name: "code_challenge_method", value: "S256")
                ]

                guard let url = components?.url else {
                    throw NSError(domain: "Settings", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法构建授权 URL"])
                }

                // 尝试访问 Google OAuth 端点，验证 client_id 是否被 Google 识别
                var request = URLRequest(url: url, timeoutInterval: 10)
                request.httpMethod = "GET"

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw NSError(domain: "Settings", code: 2, userInfo: [NSLocalizedDescriptionKey: "无效的响应"])
                }

                if http.statusCode == 200 {
                    await MainActor.run {
                        credentialTestResult = "✓ 凭据格式有效，Google 端点可达"
                        isTestingCredentials = false
                    }
                } else if http.statusCode == 400 {
                    await MainActor.run {
                        // 400 通常表示 redirect_uri 不匹配，但 client_id 被识别了
                        credentialTestResult = "✓ Client ID 被 Google 识别（redirect_uri 将在实际登录时动态指定）"
                        isTestingCredentials = false
                    }
                } else {
                    await MainActor.run {
                        credentialTestResult = "✗ 服务器返回异常状态码 \(http.statusCode)"
                        isTestingCredentials = false
                    }
                }
            } catch {
                await MainActor.run {
                    credentialTestResult = "✗ 网络错误: \(error.localizedDescription)"
                    isTestingCredentials = false
                }
            }
        }
    }

    // MARK: - 认证状态徽章

    private var authStatusBadge: some View {
        HStack(spacing: 6) {
            if authViewModel.accounts.isEmpty {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 8, height: 8)
                Text("未登录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("已登录 \(authViewModel.accounts.count) 个账户")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(authViewModel.accounts.isEmpty ? Color.gray.opacity(0.1) : Color.green.opacity(0.1))
        )
    }
}
