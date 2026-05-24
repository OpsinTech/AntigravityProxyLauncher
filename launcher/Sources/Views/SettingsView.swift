import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: LauncherAppState
    @State private var revealGoogleClientSecret = false

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
                    // 自动化流程卡片
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "bolt.fill")
                                .foregroundStyle(.orange)
                            Text("自动化流程")
                                .font(.headline)
                        }
                        
                        Divider()

                        Toggle("修复失败时自动导出诊断包", isOn: $appState.settingsDraft.autoExportDiagnosticsOnFailure)
                            .toggleStyle(.switch)

                        Toggle("修复完成后自动启动应用", isOn: $appState.settingsDraft.autoLaunchAfterPatch)
                            .toggleStyle(.switch)
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

                            Button(revealGoogleClientSecret ? "隐藏" : "显示") {
                                revealGoogleClientSecret.toggle()
                            }
                            .buttonStyle(.bordered)
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
                    
                    // 防护与指纹规则卡片
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "checkmark.shield")
                                .foregroundStyle(.green)
                            Text("系统兼容性与拦截边界")
                                .font(.headline)
                        }
                        
                        Divider()

                        HStack {
                            Text("下发路由 URL")
                                .frame(width: 100, alignment: .leading)
                            TextField("预留: compatibility.json 的下发接口", text: $appState.settingsDraft.compatibilityRulesURL)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack {
                            Text("授信根通讯端")
                                .frame(width: 100, alignment: .leading)
                            TextField("逗号分隔，如 raw.githubusercontent.com", text: $appState.settingsDraft.compatibilityTrustedHosts)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack {
                            Text("预留哈希快照")
                                .frame(width: 100, alignment: .leading)
                            TextField("可选: 用于数据下发时的本地 SHA256 强校验锁定", text: $appState.settingsDraft.compatibilityExpectedSHA256)
                                .textFieldStyle(.roundedBorder)
                        }
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
                            Text("更新信息 URL")
                                .frame(width: 100, alignment: .leading)
                            TextField("预留: release.json 的下发接口", text: $appState.settingsDraft.releaseFeedURL)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Text("授信根通讯端")
                                .frame(width: 100, alignment: .leading)
                            TextField("逗号分隔，如 raw.githubusercontent.com", text: $appState.settingsDraft.releaseFeedTrustedHosts)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack(spacing: 10) {
                            Button("检查更新") {
                                appState.checkLauncherUpdates(manual: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)

                            if let info = appState.releaseUpdateInfo, info.isUpdateAvailable {
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

                                Button("恢复提醒") {
                                    appState.clearIgnoredReleaseVersion()
                                }
                                .buttonStyle(.bordered)
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

                    // 运行日志 (Run Logs) 卡片
                    VStack(alignment: .leading, spacing: 16) {
                        Section(header: Text("运行日志 (Run Logs)").font(.headline)) {
                            Divider()
                            
                            Toggle("启用运行日志日志", isOn: $appState.settingsDraft.enableRuntimeLog)
                                .toggleStyle(.switch)

                            Picker("日志等级", selection: $appState.settingsDraft.runtimeLogLevel) {
                                Text("Debug").tag("Debug")
                                Text("Info").tag("Info")
                                Text("Warn").tag("Warn")
                                Text("Error").tag("Error")
                            }

                            Stepper("刷新时间: \(appState.settingsDraft.runtimeLogRefreshInterval) 秒", value: $appState.settingsDraft.runtimeLogRefreshInterval, in: 1...60)
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
                            Button("恢复系统默认") {
                                appState.loadSettings()
                            }
                            
                            Button(action: {
                                appState.saveSettings()
                            }) {
                                HStack {
                                    Image(systemName: "square.and.arrow.down")
                                    Text("保存并应用参数")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.gray)
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
