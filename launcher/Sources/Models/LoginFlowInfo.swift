import Foundation

/// 登录流程的实时信息，描述 OAuth 授权的当前进度。
struct LoginFlowInfo: Equatable {
    var state: LoginFlowState
    var authURL: URL?
    var errorMessage: String?

    static let idle = LoginFlowInfo(state: .idle, authURL: nil, errorMessage: nil)
}
