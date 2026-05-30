import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var appState: LauncherAppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "ladybug.fill")
                            .font(.title2)
                            .foregroundStyle(.pink)
                        Text("系统诊断")
                            .font(.title2)
                            .bold()
                    }

                    Text("验证底层注入与网络鉴权。遭遇致命异常时，可在此封转快照生成系统日志包供排查。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 32)
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Button(action: {
                            appState.verifyPatchedApp()
                        }) {
                            Image(systemName: "checkmark.shield")
                            Text("测试底层验证")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isRunningWorkflow)
                        .tint(.pink)

                        Button(action: {
                            appState.exportDiagnostics()
                        }) {
                            Image(systemName: "doc.zipper")
                            Text("导出诊断快照")
                        }
                        .buttonStyle(.bordered)
                        .disabled(appState.isRunningWorkflow)
                    }

                    Group {
                        if let message = appState.lastVerifyMessage {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text(message)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.green)
                        }

                        if let error = appState.lastVerifyError {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                Text(error)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.red)
                        }

                        if let path = appState.lastExportPath {
                            HStack(alignment: .top) {
                                Image(systemName: "folder.badge.gearshape")
                                Text("已提取系统快照至: \(path)")
                                    .textSelection(.enabled)
                            }
                            .font(.caption)
                            .foregroundStyle(.blue)
                        }

                        if let error = appState.lastExportError {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("提取拦截: \(error)")
                            }
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                )

                // Log file card
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "doc.text.viewfinder")
                            .foregroundStyle(.gray)
                        Text("日志文件目录")
                            .font(.headline)
                    }
                    Text(FileSystemPaths.patchLogFile.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                )

                HStack(alignment: .top, spacing: 16) {
                    // Failure Aggregates Card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "chart.bar.xaxis")
                                .foregroundStyle(.orange)
                            Text("系统失败聚合")
                                .font(.headline)
                        }

                        if appState.failureAggregates.isEmpty {
                            Text("暂无失败样本")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        } else {
                            ForEach(appState.failureAggregates) { item in
                                HStack(alignment: .top) {
                                    Text(item.reason)
                                        .font(.caption)
                                    Spacer()
                                    Text("\(item.count) 次")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
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

                    // Diagnostics History Card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.blue)
                            Text("追溯历史")
                                .font(.headline)
                        }

                        if appState.diagnosticsHistory.isEmpty {
                            Text("暂无诊断记录")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(appState.diagnosticsHistory) { entry in
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(entry.statusTitle)
                                                    .font(.caption)
                                                    .bold()
                                                if entry.hasFailure {
                                                    Text("失败")
                                                        .font(.caption2)
                                                        .padding(.horizontal, 4)
                                                        .padding(.vertical, 2)
                                                        .background(Color.red.opacity(0.1))
                                                        .foregroundStyle(.red)
                                                        .clipShape(Capsule())
                                                }
                                                Spacer()
                                                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Text(entry.folderPath)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        
                                        Divider().opacity(0.5)
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
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
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "questionmark.bubble")
                            .foregroundStyle(.indigo)
                        Text("常见问题")
                            .font(.headline)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        FAQRow(
                            question: "修复流程失败了怎么办？",
                            answer: "先点击“导出诊断快照”，再查看实时日志里最后一个失败阶段；修复配置后点击“测试底层验证”复测。"
                        )
                        FAQRow(
                            question: "验证通过但应用仍异常，怎么排查？",
                            answer: "先刷新状态，然后到“日志文件目录”定位日志并核对最近错误；必要时清理环境后重新执行修复。"
                        )
                        FAQRow(
                            question: "提示版本不兼容怎么办？",
                            answer: "前往设置页更新兼容规则并刷新状态；若仍不支持，请先使用已兼容的目标应用版本。"
                        )
                        FAQRow(
                            question: "诊断记录有什么用？",
                            answer: "“追溯历史”会记录每次诊断结果和路径，可用于复盘故障时间点与复现步骤。"
                        )
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                )

                Spacer()
            }
            .padding(24)
        }
        .onAppear {
            DispatchQueue.main.async {
                appState.reloadDiagnosticsHistory()
            }
        }
    }
}

private struct FAQRow: View {
    let question: String
    let answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question)
                .font(.subheadline)
                .bold()
            Text(answer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
