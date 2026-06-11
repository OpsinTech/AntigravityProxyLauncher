import SwiftUI

struct ConfigView: View {
    @EnvironmentObject private var appState: LauncherAppState

    private var portText: Binding<String> {
        Binding(
            get: { String(appState.proxyConfigDraft.proxy.port) },
            set: { input in
                let digits = input.filter { $0.isNumber }
                guard !digits.isEmpty else { return }
                if let value = Int(digits) {
                    appState.proxyConfigDraft.proxy.port = min(max(value, 1), 65535)
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        Text("代理配置")
                            .font(.title2)
                            .bold()
                    }

                    Text("设定底层网络上游拦截策略与代理节点。修改后如应用正在运行，需重启后生效。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 32)
                }

                VStack(alignment: .leading, spacing: 20) {
                    // 代理节点设定卡片
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "network")
                                .foregroundStyle(.blue)
                            Text("代理节点规则")
                                .font(.headline)
                        }
                        
                        Divider()

                        HStack {
                            Text("代理类型")
                                .frame(width: 100, alignment: .leading)
                            TextField("SOCKS5 / HTTP 等", text: $appState.proxyConfigDraft.proxy.type)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Text("节点主机")
                                .frame(width: 100, alignment: .leading)
                            TextField("例如 127.0.0.1", text: $appState.proxyConfigDraft.proxy.host)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("监听端口")
                                    .frame(width: 100, alignment: .leading)
                                TextField("1-65535", text: portText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 160)
                            }
                            Text("通常指向上游 Clash 或 Mihomo 监听的本地入口。(而非目标应用端口)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 108)
                        }
                    }
                    .padding(20)
                    .background(Color.gray.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                    )

                    // 特性与路由卡片
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "externaldrive.badge.wifi")
                                .foregroundStyle(.purple)
                            Text("特性与路由控制")
                                .font(.headline)
                        }
                        
                        Divider()

                        Toggle("启用 FakeIP (内网 IP 伪装模式)", isOn: $appState.proxyConfigDraft.fakeIP.enabled)
                            .toggleStyle(.switch)

                        HStack {
                            Text("内网路由表")
                                .frame(width: 100, alignment: .leading)
                                .foregroundStyle(appState.proxyConfigDraft.fakeIP.enabled ? .primary : .secondary)
                            TextField("CIDR 网段配置, 例如 198.18.0.0/15", text: $appState.proxyConfigDraft.fakeIP.cidr)
                                .textFieldStyle(.roundedBorder)
                                .disabled(!appState.proxyConfigDraft.fakeIP.enabled)
                        }

                        HStack {
                            Text("日志诊断级别")
                                .frame(width: 100, alignment: .leading)
                            TextField("DEBUG / INFO / ERROR", text: $appState.proxyConfigDraft.logLevel)
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

                    // 控制卡片
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Button("恢复默认") {
                                appState.proxyConfigDraft = .default
                                appState.configStatusMessage = "已恢复默认配置，请点击保存以生效。"
                            }
                            
                            Button(action: {
                                appState.saveProxyConfig()
                            }) {
                                HStack {
                                    Image(systemName: "square.and.arrow.down")
                                    Text("保存并应用配置")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            
                            Spacer()
                            
                            if let message = appState.configStatusMessage {
                                Text(message)
                                    .font(.subheadline)
                                    .foregroundStyle(.green)
                            }

                            if let error = appState.configErrorMessage {
                                Text(error)
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                            }
                        }
                        
                        Divider()
                        
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(.secondary)
                            Text("系统代理重定向配置文件映射地址: \(FileSystemPaths.userProxyConfigFile.path)")
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
                appState.loadProxyConfigIfNeeded()
            }
        }
        .onDisappear {
            DispatchQueue.main.async {
                appState.clearConfigStatusMessage()
            }
        }
    }
}
