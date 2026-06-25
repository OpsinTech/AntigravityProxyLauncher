import SwiftUI

// MARK: - Data model

private enum FileReferenceSection: CaseIterable {
    case logs
    case configs

    var title: String {
        switch self {
        case .logs: return "日志文件"
        case .configs: return "配置文件"
        }
    }

    var iconName: String {
        switch self {
        case .logs: return "doc.text.magnifyingglass"
        case .configs: return "gearshape.2"
        }
    }
}

private struct FileReferenceEntry: Identifiable {
    let id = UUID()
    let label: String
    let path: String
    let iconName: String
    let section: FileReferenceSection
    let usesDirectoryForReveal: Bool
}

// MARK: - Path builder

private func buildFileEntries() -> [FileReferenceEntry] {
    let home = FileManager.default.homeDirectoryForCurrentUser

    // ── 日志文件（全局） ──
    var entries: [FileReferenceEntry] = [
        FileReferenceEntry(
            label: "Dylib 运行日志",
            path: home.appendingPathComponent(".config/antigravity").path,
            iconName: "doc.text",
            section: .logs,
            usesDirectoryForReveal: true
        ),
        FileReferenceEntry(
            label: "Go 代理日志",
            path: home.appendingPathComponent(".config/antigravity/mitm_proxy.log").path,
            iconName: "terminal",
            section: .logs,
            usesDirectoryForReveal: false
        ),
        FileReferenceEntry(
            label: "修复流程日志",
            path: FileSystemPaths.patchLogFile.path,
            iconName: "wrench.and.screwdriver",
            section: .logs,
            usesDirectoryForReveal: false
        ),

    ]

    // ── 配置文件（全局） ──
    entries.append(FileReferenceEntry(
        label: "偏好设置",
        path: FileSystemPaths.settingsFile.path,
        iconName: "gearshape",
        section: .configs,
        usesDirectoryForReveal: false
    ))
    entries.append(FileReferenceEntry(
        label: "模型映射配置",
        path: FileSystemPaths.userModelRoutingConfigFile.path,
        iconName: "arrow.triangle.branch",
        section: .configs,
        usesDirectoryForReveal: false
    ))
    entries.append(FileReferenceEntry(
        label: "MITM CA 证书",
        path: home.appendingPathComponent(".config/antigravity/goproxy_ca.pem").path,
        iconName: "lock.shield",
        section: .configs,
        usesDirectoryForReveal: false
    ))

    // ── 配置文件（全局代理配置） ──
    entries.append(FileReferenceEntry(
        label: "代理配置",
        path: FileSystemPaths.userProxyConfigFile.path,
        iconName: "slider.horizontal.3",
        section: .configs,
        usesDirectoryForReveal: false
    ))

    return entries
}

// MARK: - Main view

struct DiagnosticsView: View {
    @EnvironmentObject private var appState: LauncherAppState
    @State private var entries: [FileReferenceEntry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        Text("系统诊断")
                            .font(.title2)
                            .bold()
                    }
                    Text("查看平台所有日志与配置文件的存储路径，便于问题排查与手动定位。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 32)
                }

                // Section cards
                ForEach(FileReferenceSection.allCases, id: \.self) { section in
                    let sectionEntries = entries.filter { $0.section == section }
                    FileReferenceSectionCard(section: section, entries: sectionEntries)
                }

                Spacer()
            }
            .padding(24)
        }
        .onAppear {
            entries = buildFileEntries()
        }
    }
}

// MARK: - Section card

private struct FileReferenceSectionCard: View {
    let section: FileReferenceSection
    let entries: [FileReferenceEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: section.iconName)
                    .foregroundStyle(section == .logs ? .orange : .purple)
                Text(section.title)
                    .font(.headline)
            }

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    FileReferenceRow(entry: entry)
                    if entry.id != entries.last?.id {
                        Divider()
                            .opacity(0.4)
                            .padding(.leading, 28)
                    }
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
    }
}

// MARK: - Row

private struct FileReferenceRow: View {
    let entry: FileReferenceEntry

    @State private var isHovered = false
    @State private var justCopied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.iconName)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(entry.label)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .help(entry.label)

            Text(entry.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.path)
                .textSelection(.enabled)

            Spacer()

            if isHovered {
                HStack(spacing: 4) {
                    Button(action: copyPath) {
                        Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    }
                    .iconButtonStyle()
                    .help(justCopied ? "已复制" : "复制路径")

                    Button(action: revealInFinder) {
                        Image(systemName: "arrow.right.to.line.compact")
                    }
                    .iconButtonStyle()
                    .help("在 Finder 中显示")
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.path, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            justCopied = false
        }
    }

    private func revealInFinder() {
        let url = URL(fileURLWithPath: entry.path)
        if entry.usesDirectoryForReveal {
            NSWorkspace.shared.open(url)
        } else {
            let parentDir = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parentDir.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(parentDir)
            }
        }
    }
}
