import AppKit
import Combine
import CryptoKit
import Foundation

enum GoogleOAuthError: Error {
    case missingClientCredential
    case invalidClientCredential(String)
    case callbackServerUnavailable
    case openBrowserFailed(String)
    case invalidTokenResponse
    case missingRefreshToken
    case invalidUserInfoResponse
    case noActiveAccount
    case notAuthenticated
    case tokenExpired
}

extension GoogleOAuthError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingClientCredential:
            return "缺少有效的 Google OAuth 凭据。请在设置页填写并保存 Client ID / Client Secret，或设置环境变量 AG_GOOGLE_CLIENT_ID / AG_GOOGLE_CLIENT_SECRET。"
        case .invalidClientCredential(let detail):
            if detail.isEmpty {
                return "Google OAuth 客户端配置无效（invalid_client）。请检查 Client ID / Client Secret 是否正确。"
            }
            return "Google OAuth 客户端配置无效（invalid_client）：\(detail)"
        case .callbackServerUnavailable:
            return "OAuth callback server is unavailable."
        case .openBrowserFailed(let authURL):
            return "无法打开浏览器，请手动访问授权地址: \(authURL)"
        case .invalidTokenResponse:
            return "Invalid token response from Google OAuth endpoint."
        case .missingRefreshToken:
            return "No refresh token returned by OAuth provider."
        case .invalidUserInfoResponse:
            return "Invalid user info response from Google API."
        case .noActiveAccount:
            return "No active account."
        case .notAuthenticated:
            return "Not authenticated."
        case .tokenExpired:
            return "Token has expired."
        }
    }
}

// LoginFlowInfo 已移至 Models/LoginFlowInfo.swift

final class GoogleOAuthService {
    private struct OAuthErrorResponse: Decodable {
        let error: String?
        let error_description: String?
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let token_type: String
        let scope: String
    }

    private struct UserInfoResponse: Decodable {
        let id: String
        let email: String
        let name: String?
        let picture: String?
    }

    private let callbackServer: OAuthCallbackServer
    private let tokenStore: TokenStoreService
    private let accountStore: AccountStoreService
    private let session: URLSession

    // MARK: - Reactive State (via Combine)
    //
    // 外部通过订阅 authStatePublisher / loginFlowInfoPublisher 获得响应式更新，
    // 也可通过 getAuthStateInfo() / getLoginFlowInfo() 同步读取当前值。

    private let authStateSubject: CurrentValueSubject<AuthState, Never> = .init(.notAuthenticated)
    private let loginFlowInfoSubject: CurrentValueSubject<LoginFlowInfo, Never> = .init(.idle)

    var authStatePublisher: AnyPublisher<AuthState, Never> {
        authStateSubject.eraseToAnyPublisher()
    }

    var loginFlowInfoPublisher: AnyPublisher<LoginFlowInfo, Never> {
        loginFlowInfoSubject.eraseToAnyPublisher()
    }

    private(set) var authState: AuthState {
        get { authStateSubject.value }
        set { authStateSubject.send(newValue) }
    }

    private(set) var loginFlowInfo: LoginFlowInfo {
        get { loginFlowInfoSubject.value }
        set { loginFlowInfoSubject.send(newValue) }
    }

    init(
        callbackServer: OAuthCallbackServer = OAuthCallbackServer(),
        tokenStore: TokenStoreService = TokenStoreService(),
        accountStore: AccountStoreService = AccountStoreService(),
        session: URLSession = .shared
    ) {
        self.callbackServer = callbackServer
        self.tokenStore = tokenStore
        self.accountStore = accountStore
        self.session = session
    }

    func initialize() {
        do {
            if try accountStore.getActiveAccount() != nil {
                authState = .authenticated
            } else {
                authState = .notAuthenticated
            }
        } catch {
            authState = .error(error.localizedDescription)
        }
    }

    func getAuthStateInfo() -> AuthState {
        authState
    }

    func getLoginFlowInfo() -> LoginFlowInfo {
        loginFlowInfo
    }

    func login() async throws -> GoogleAccount {
        guard OAuthConstants.hasValidClientCredential else {
            authState = .error(GoogleOAuthError.missingClientCredential.localizedDescription)
            throw GoogleOAuthError.missingClientCredential
        }

        authState = .authenticating
        loginFlowInfo = LoginFlowInfo(state: .preparing, authURL: nil, errorMessage: nil)

        let state = randomURLSafeString()
        let codeVerifier = randomURLSafeString()
        let codeChallenge = sha256Base64URL(of: codeVerifier)

        try await callbackServer.start()
        guard let redirectURL = URL(string: callbackServer.redirectURI), !callbackServer.redirectURI.isEmpty else {
            authState = .error(GoogleOAuthError.callbackServerUnavailable.localizedDescription)
            throw GoogleOAuthError.callbackServerUnavailable
        }

        let authURL = try buildAuthURL(redirectURI: redirectURL, state: state, codeChallenge: codeChallenge)
        loginFlowInfo = LoginFlowInfo(state: .openingBrowser, authURL: authURL, errorMessage: nil)

        let didOpen = NSWorkspace.shared.open(authURL)
        if !didOpen {
            authState = .error(GoogleOAuthError.openBrowserFailed(authURL.absoluteString).localizedDescription)
            throw GoogleOAuthError.openBrowserFailed(authURL.absoluteString)
        }
        loginFlowInfo = LoginFlowInfo(state: .waitingAuthorization, authURL: authURL, errorMessage: nil)

        do {
            let callbackResult = try await callbackServer.waitForCallback(expectedState: state)
            loginFlowInfo = LoginFlowInfo(state: .exchangingToken, authURL: authURL, errorMessage: nil)

            let token = try await exchangeCodeForToken(
                code: callbackResult.code,
                redirectURI: redirectURL.absoluteString,
                codeVerifier: codeVerifier
            )

            let userInfo = try await fetchUserInfo(accessToken: token.accessToken)
            let account = GoogleAccount(
                id: userInfo.id,
                email: userInfo.email,
                name: userInfo.name,
                avatarURL: userInfo.picture,
                isActive: true
            )

            try accountStore.saveAccount(account)
            try accountStore.setActiveAccountId(account.id)
            try tokenStore.saveToken(token, for: account.id)

            authState = .authenticated
            loginFlowInfo = LoginFlowInfo(state: .success, authURL: authURL, errorMessage: nil)
            callbackServer.stop()
            return account
        } catch {
            authState = .error(error.localizedDescription)
            loginFlowInfo = LoginFlowInfo(state: .error, authURL: authURL, errorMessage: error.localizedDescription)
            callbackServer.stop()
            throw error
        }
    }

    func cancelLogin() {
        callbackServer.stop()
        loginFlowInfo = LoginFlowInfo(state: .cancelled, authURL: loginFlowInfo.authURL, errorMessage: nil)
        if case .authenticated = authState {
            return
        }
        authState = .notAuthenticated
    }

    func logout(accountId: String? = nil) throws {
        let targetId: String
        if let accountId {
            targetId = accountId
        } else if let active = try accountStore.getActiveAccountId() {
            targetId = active
        } else {
            return
        }

        try tokenStore.deleteToken(for: targetId)
        try accountStore.deleteAccount(accountId: targetId)

        if let active = try accountStore.getActiveAccount(), tokenStore.hasToken(for: active.id) {
            authState = .authenticated
        } else {
            authState = .notAuthenticated
        }
    }

    func getAccounts() throws -> [GoogleAccount] {
        try accountStore.loadAccounts()
    }

    func getActiveAccount() throws -> GoogleAccount? {
        try accountStore.getActiveAccount()
    }

    func getActiveAccountId() throws -> String? {
        try accountStore.getActiveAccountId()
    }

    func setActiveAccount(_ accountId: String) throws {
        try accountStore.setActiveAccountId(accountId)
    }

    func getValidAccessToken(accountId: String? = nil, allowUserInteraction: Bool = true) async throws -> String {
        let targetId: String
        if let accountId {
            targetId = accountId
        } else if let activeId = try accountStore.getActiveAccountId() {
            targetId = activeId
        } else {
            authState = .notAuthenticated
            throw GoogleOAuthError.noActiveAccount
        }

        guard var token = try tokenStore.loadToken(for: targetId, allowUserInteraction: allowUserInteraction) else {
            authState = .notAuthenticated
            throw GoogleOAuthError.notAuthenticated
        }

        // 如果令牌即将过期，自动刷新
        if token.isExpiring() {
            authState = .refreshing
            token = try await refreshToken(token, accountId: targetId, allowUserInteraction: allowUserInteraction)
            authState = .authenticated
        }

        return token.accessToken
    }

    private func buildAuthURL(redirectURI: URL, state: String, codeChallenge: String) throws -> URL {
        var components = URLComponents(url: OAuthConstants.authEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthConstants.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: OAuthConstants.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let url = components?.url else {
            throw GoogleOAuthError.callbackServerUnavailable
        }
        return url
    }

    private func exchangeCodeForToken(code: String, redirectURI: String, codeVerifier: String) async throws -> OAuthToken {
        var request = URLRequest(url: OAuthConstants.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": OAuthConstants.clientID,
            "client_secret": OAuthConstants.clientSecret,
            "code": code,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let oauthError = parseOAuthError(from: data)
            if oauthError.code == "invalid_client" {
                throw GoogleOAuthError.invalidClientCredential(oauthError.description)
            }
            throw GoogleOAuthError.invalidTokenResponse
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refreshToken = decoded.refresh_token, !refreshToken.isEmpty else {
            throw GoogleOAuthError.missingRefreshToken
        }

        return OAuthToken(
            accessToken: decoded.access_token,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)),
            tokenType: decoded.token_type,
            scope: decoded.scope
        )
    }

    private func refreshToken(_ token: OAuthToken, accountId: String, allowUserInteraction: Bool) async throws -> OAuthToken {
        var request = URLRequest(url: OAuthConstants.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": OAuthConstants.clientID,
            "client_secret": OAuthConstants.clientSecret,
            "refresh_token": token.refreshToken,
            "grant_type": "refresh_token"
        ]
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let oauthError = parseOAuthError(from: data)
            if oauthError.code == "invalid_client" {
                authState = .error(GoogleOAuthError.invalidClientCredential(oauthError.description).localizedDescription)
                throw GoogleOAuthError.invalidClientCredential(oauthError.description)
            }
            authState = .tokenExpired
            throw GoogleOAuthError.invalidTokenResponse
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        let refreshed = OAuthToken(
            accessToken: decoded.access_token,
            refreshToken: token.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)),
            tokenType: decoded.token_type,
            scope: decoded.scope
        )

        try tokenStore.saveToken(refreshed, for: accountId, allowUserInteraction: allowUserInteraction)
        return refreshed
    }

    private func fetchUserInfo(accessToken: String) async throws -> UserInfoResponse {
        var request = URLRequest(url: OAuthConstants.userInfoEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw GoogleOAuthError.invalidUserInfoResponse
        }

        return try JSONDecoder().decode(UserInfoResponse.self, from: data)
    }

    private func randomURLSafeString(length: Int = 32) -> String {
        let raw = Data((0..<length).map { _ in UInt8.random(in: 0...255) })
        return raw.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func sha256Base64URL(of input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func parseOAuthError(from data: Data) -> (code: String, description: String) {
        guard let decoded = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) else {
            return ("", "")
        }

        let code = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = decoded.error_description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (code, description)
    }
}
