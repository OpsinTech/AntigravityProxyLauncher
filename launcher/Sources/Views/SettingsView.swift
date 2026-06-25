import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: LauncherAppState
    @State private var revealGoogleClientSecret = false
    @State private var revealGithubToken = false

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

                    // 监控与轮询卡片
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.blue)
                            Text("配额监控轮询")
                                .font(.headline)
                        }
                        
                        Divider()

                        Toggle("配额信息后台静默自动刷新", isOn: $appState.settingsDraft.quotaAutoRefreshEnabled)
                            .toggleStyle(.switch)

                        HStack {
                            Text("轮询时间间隔")
                                .frame(width: 100, alignment: .leading)
                                .foregroundStyle(appState.settingsDraft.quotaAutoRefreshEnabled ? .primary : .secondary)
                            
                            TextField("以 秒 为单位，默认 60 秒", value: $appState.settingsDraft.quotaPollingIntervalSeconds, formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 160)
                                .disabled(!appState.settingsDraft.quotaAutoRefreshEnabled)
                        }
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
                        }

                        Divider()

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

                        Text("说明：若同时设置了环境变量 AG_GOOGLE_CLIENT_ID / AG_GOOGLE_CLIENT_SECRET，环境变量优先。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("点击底部“保存并应用参数”后会持久化到本地设置文件，后续可直接登录。")
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
            DispatchQueue.main.async {
                appState.loadSettings()
            }
        }
    }
}
