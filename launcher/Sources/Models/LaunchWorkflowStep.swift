import Foundation

enum LaunchWorkflowStep: String, CaseIterable, Identifiable {
    case detect = "检测目标应用"
    case migration = "迁移历史数据"
    case patch = "修复应用包"
    case verify = "验证修复结果"
    case launch = "启动修复版"

    var id: String { rawValue }
}

enum LaunchWorkflowStepState {
    case pending
    case running
    case completed
    case failed
}

struct LaunchWorkflowItem: Identifiable {
    let id: LaunchWorkflowStep
    var state: LaunchWorkflowStepState
    var detail: String?

    var title: String {
        id.rawValue
    }
}
