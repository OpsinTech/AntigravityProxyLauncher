import SwiftUI
import Combine
import Foundation

struct RuntimeLogsView: View {
    @EnvironmentObject var appState: LauncherAppState
    
    @State private var logContent: String = ""
    @State private var currentLogPath: String = "未找到日志文件"
    @State private var timer: AnyCancellable?
    
    // Read the last 20KB of the file
    private let maxReadBytes: Int = 20 * 1024
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部的统一 4 字标题栏，与所有其他面板保持绝对的一致性
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    Text("运行日志")
                        .font(.title2)
                        .bold()
                }
                Text("查看底层拦截器的系统标准输出与错误数据流，实时轮询自检。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 32)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
            
            Divider()

            if !appState.settingsDraft.enableRuntimeLog {
                Spacer()
                Text("如果需要查看运行日志，请在设置中开启「启用运行日志」功能。")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            } else {
                HStack {
                    Text("当前监听日志: \(currentLogPath)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(action: refreshLog) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                ScrollView {
                    Text(logContent)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding()
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
        .onAppear {
            setupTimer()
            refreshLog()
        }
        .onDisappear {
            timer?.cancel()
        }
        .onChange(of: appState.settingsDraft.enableRuntimeLog) { _ in
            setupTimer()
            if appState.settingsDraft.enableRuntimeLog {
                refreshLog()
            }
        }
        .onChange(of: appState.settingsDraft.runtimeLogRefreshInterval) { _ in
            setupTimer()
        }
    }
    
    private func setupTimer() {
        timer?.cancel()
        if appState.settingsDraft.enableRuntimeLog {
            let interval = Double(appState.settingsDraft.runtimeLogRefreshInterval)
            timer = Timer.publish(every: interval > 0 ? interval : 5, on: .main, in: .common)
                .autoconnect()
                .sink { _ in
                    refreshLog()
                }
        }
    }
    
    private func refreshLog() {
        guard appState.settingsDraft.enableRuntimeLog else { return }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            let preferredLog = FileSystemPaths.runtimeLogFile

            if fileManager.fileExists(atPath: preferredLog.path) {
                let content = readLastBytes(of: preferredLog.path, maxBytes: maxReadBytes)
                DispatchQueue.main.async {
                    self.currentLogPath = preferredLog.path
                    self.logContent = content
                }
                return
            }

            guard let newestLog = findNewestTmpLog(fileManager: fileManager) else {
                DispatchQueue.main.async {
                    self.currentLogPath = "未找到日志文件"
                    self.logContent = "暂无日志。已检查:\n\(preferredLog.path)\n/tmp/antigravity_proxy*.log"
                }
                return
            }

            let path = newestLog.path
            let content = readLastBytes(of: path, maxBytes: maxReadBytes)

            DispatchQueue.main.async {
                self.currentLogPath = path
                self.logContent = content
            }
        }
    }

    private func findNewestTmpLog(fileManager: FileManager) -> URL? {
        let tmpDir = URL(fileURLWithPath: "/tmp")
        guard let contents = try? fileManager.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return nil
        }

        let logFiles = contents.filter {
            $0.lastPathComponent.hasPrefix("antigravity_proxy") && $0.lastPathComponent.hasSuffix(".log")
        }

        return logFiles.max(by: { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return dateA < dateB
        })
    }
    
    private func readLastBytes(of path: String, maxBytes: Int) -> String {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            return "无法打开文件: \(path)"
        }
        defer {
            try? fileHandle.close()
        }
        do {
            let fileManager = FileManager.default
            let attrs = try fileManager.attributesOfItem(atPath: path)
            let fileSize = attrs[.size] as? UInt64 ?? 0
            
            let offset = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0
            try fileHandle.seek(toOffset: offset)
            let data = fileHandle.readDataToEndOfFile()
            
            if let string = String(data: data, encoding: .utf8) {
                return offset > 0 ? "...\n" + string : string
            } else if let string = String(data: data, encoding: .ascii) {
                return offset > 0 ? "...\n" + string : string
            } else {
                return "无法解析日志内容 (非UTF-8文本)。"
            }
        } catch {
            return "读取日志文件内容时发生错误: \(error.localizedDescription)"
        }
    }
}
