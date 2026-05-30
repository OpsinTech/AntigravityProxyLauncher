import Foundation

enum AppStatus: Equatable {
    case targetAppMissing
    case targetAppUnsupportedVersion(String)
    case targetAppInstalled
    case patchedAppMissing
    case patchedAppOutdated
    case patching
    case cleaning
    case patchedReady
    case launching
    case running
    case repairRequired(String)
    case error(String)

    var title: String {
        let appName = FileSystemPaths.activeApp.displayName
        let isCLI = FileSystemPaths.activeApp.targetType == .cliBinary
        switch self {
        case .targetAppMissing:
            return "未检测到 \(appName)"
        case .targetAppUnsupportedVersion:
            return "版本不受支持"
        case .targetAppInstalled:
            return "\(appName) 已安装"
        case .patchedAppMissing:
            return "未发现修复版"
        case .patchedAppOutdated:
            return "修复版已过期"
        case .patching:
            return "正在修复"
        case .cleaning:
            return "正在清理环境"
        case .patchedReady:
            return "修复完成"
        case .launching:
            return isCLI ? "正在验证" : "正在启动"
        case .running:
            return isCLI ? "Agy CLI 可用" : "运行中"
        case .repairRequired:
            return "需要修复"
        case .error:
            return "错误"
        }
    }

    var description: String {
        let appName = FileSystemPaths.activeApp.displayName
        let isCLI = FileSystemPaths.activeApp.targetType == .cliBinary
        switch self {
        case .targetAppMissing:
            return "请先安装 \(isCLI ? "agy CLI" : appName): \(FileSystemPaths.targetApp.path)"
        case .targetAppUnsupportedVersion(let version):
            return "当前版本 \(version) 不在兼容列表中。"
        case .targetAppInstalled:
            return "可执行修复流程。"
        case .patchedAppMissing:
            return "尚未生成修复版。"
        case .patchedAppOutdated:
            return "检测到原版已更新，需要重新修复。"
        case .patching:
            return "正在复制、注入资源并写入元数据。"
        case .cleaning:
            return "正在移除修复版及相关配置碎片。"
        case .patchedReady:
            return isCLI ? "修复完成，可在终端使用 agy 命令。" : "可以启动修复版。"
        case .launching:
            return isCLI ? "正在运行 agy --version 验证安装..." : "正在拉起修复版应用。"
        case .running:
            return isCLI ? "代理注入已就绪，终端执行 agy 将自动走代理。" : "修复版正在运行。"
        case .repairRequired(let reason):
            return reason
        case .error(let message):
            return message
        }
    }
}
