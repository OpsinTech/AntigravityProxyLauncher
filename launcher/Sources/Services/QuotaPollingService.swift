import Foundation

final class QuotaPollingService {
    private let authService: GoogleOAuthService
    private let apiClient: QuotaApiClient
    private let cacheService: QuotaCacheService

    private var pollingTask: Task<Void, Never>?

    init(
        authService: GoogleOAuthService = GoogleOAuthService(),
        apiClient: QuotaApiClient = QuotaApiClient(),
        cacheService: QuotaCacheService = QuotaCacheService()
    ) {
        self.authService = authService
        self.apiClient = apiClient
        self.cacheService = cacheService
    }

    func refreshActiveAccountQuota(ideType: String = "ANTIGRAVITY") async throws -> (String, QuotaSnapshot) {
        guard let activeAccount = try authService.getActiveAccount() else {
            throw GoogleOAuthError.noActiveAccount
        }

        return try await refreshQuota(for: activeAccount, ideType: ideType)
    }

    func refreshQuota(forAccountId accountId: String, ideType: String = "ANTIGRAVITY") async throws -> (String, QuotaSnapshot) {
        let accounts = try authService.getAccounts()
        guard let account = accounts.first(where: { $0.id == accountId }) else {
            throw GoogleOAuthError.noActiveAccount
        }

        return try await refreshQuota(for: account, ideType: ideType)
    }

    func refreshAllAccountsQuota(ideType: String = "ANTIGRAVITY") async throws -> [String: QuotaSnapshot] {
        let accounts = try authService.getAccounts()
        var snapshots: [String: QuotaSnapshot] = [:]

        for account in accounts {
            let (accountId, snapshot) = try await refreshQuota(for: account, ideType: ideType)
            snapshots[accountId] = snapshot
        }

        return snapshots
    }

    func loadCachedAllSnapshots() throws -> [String: QuotaSnapshot] {
        try cacheService.loadAllSnapshots()
    }

    private func refreshQuota(for account: GoogleAccount, ideType: String) async throws -> (String, QuotaSnapshot) {

        let maxRetries = 3
        var retryCount = 0

        while true {
            do {
                let accessToken = try await authService.getValidAccessToken(accountId: account.id, allowUserInteraction: false)
                let project = try await apiClient.loadProjectInfo(accessToken: accessToken, ideType: ideType)
                let models = try await apiClient.fetchModelsQuota(
                    accessToken: accessToken,
                    projectId: project.projectId
                )

                let snapshot = QuotaSnapshot(
                    timestamp: Date(),
                    userEmail: account.email,
                    tier: project.tier,
                    models: models
                )

                try cacheService.save(snapshot: snapshot, for: account.id)
                return (account.id, snapshot)
            } catch let error as QuotaApiError {
                if error.needsReauth {
                    throw error
                }

                if error.isRetryable, retryCount < maxRetries {
                    retryCount += 1
                    try? await Task.sleep(nanoseconds: UInt64(retryCount * 1_000_000_000))
                    continue
                }
                throw error
            } catch {
                throw error
            }
        }
    }

    func loadCachedActiveSnapshot() throws -> QuotaSnapshot? {
        guard let accountId = try authService.getActiveAccountId() else {
            return nil
        }
        return try cacheService.loadSnapshot(for: accountId)
    }

    func startPolling(intervalSeconds: TimeInterval, ideType: String = "ANTIGRAVITY", onUpdate: @escaping @MainActor ([String: QuotaSnapshot]) -> Void, onError: @escaping @MainActor (String) -> Void) {
        stopPolling()

        pollingTask = Task {
            while !Task.isCancelled {
                do {
                    let snapshots = try await refreshAllAccountsQuota(ideType: ideType)
                    await onUpdate(snapshots)
                } catch {
                    // 在自动刷新模式下，如果遇到需要用户交互的错误，不触发弹窗
                    // 而是静默失败，等待下次轮询
                    if let oauthError = error as? GoogleOAuthError {
                        if case .notAuthenticated = oauthError {
                            // 认证失效，但不触发弹窗
                            await onError("认证已失效，请手动刷新")
                        } else {
                            await onError(error.localizedDescription)
                        }
                    } else {
                        await onError(error.localizedDescription)
                    }
                }

                let delay = max(5, intervalSeconds)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
