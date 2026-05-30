import Foundation

enum QuotaModelSortOption: String, CaseIterable, Identifiable {
    case remainingAsc
    case remainingDesc
    case nameAsc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remainingAsc:
            return "按剩余从低到高"
        case .remainingDesc:
            return "按剩余从高到低"
        case .nameAsc:
            return "按名称"
        }
    }
}

enum QuotaUIStatus: Equatable {
    case notLoggedIn
    case hasCachedNotRefreshed
    case refreshing
    case refreshSuccess
    case reauthRequired
    case refreshFailed(String)

    var displayText: String {
        switch self {
        case .notLoggedIn:
            return "未登录"
        case .hasCachedNotRefreshed:
            return "已加载缓存"
        case .refreshing:
            return "刷新中"
        case .refreshSuccess:
            return "刷新成功"
        case .reauthRequired:
            return "需要重新登录"
        case .refreshFailed(let message):
            return "刷新失败: \(message)"
        }
    }
}

@MainActor
final class QuotaViewModel: ObservableObject {
    @Published private(set) var uiStatus: QuotaUIStatus = .notLoggedIn
    @Published var snapshot: QuotaSnapshot?
    @Published var snapshotsByAccount: [String: QuotaSnapshot] = [:]
    @Published var selectedAccountId: String?
    @Published var errorMessage: String?
    @Published var isPolling = false
    @Published private(set) var pollingIntervalSeconds: TimeInterval?
    @Published var sortOption: QuotaModelSortOption = .remainingAsc
    @Published var showExhaustedOnly = false

    private let pollingService: QuotaPollingService

    var lowestModels: [ModelQuotaInfo] {
        guard let snapshot, !snapshot.models.isEmpty else {
            return []
        }
        return Array(snapshot.models.sorted { $0.remainingPercentage < $1.remainingPercentage }.prefix(3))
    }

    var exhaustedModelsExist: Bool {
        snapshot?.models.contains(where: { $0.isExhausted }) ?? false
    }

    var nextResetTime: String? {
        guard let snapshot, !snapshot.models.isEmpty else {
            return nil
        }
        let nearestReset = snapshot.models
            .compactMap { $0.resetTime }
            .min()
        guard let reset = nearestReset else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: reset)
    }

    var selectedAccountHasCachedSnapshot: Bool {
        guard let accountId = selectedAccountId else { return false }
        return snapshotsByAccount[accountId] != nil
    }

    init(pollingService: QuotaPollingService = QuotaPollingService()) {
        self.pollingService = pollingService
    }

    func loadCachedSnapshot(for accountId: String? = nil) {
        do {
            snapshotsByAccount = try pollingService.loadCachedAllSnapshots()

            if let accountId, !accountId.isEmpty {
                selectedAccountId = accountId
                snapshot = snapshotsByAccount[accountId]
            } else if selectedAccountId == nil {
                selectedAccountId = snapshotsByAccount.keys.sorted().first
                snapshot = snapshotsByAccount[selectedAccountId ?? ""]
            } else {
                snapshot = snapshotsByAccount[selectedAccountId ?? ""]
            }

            updateUIStatus()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            uiStatus = .refreshFailed(error.localizedDescription)
        }
    }

    func selectAccount(_ accountId: String) {
        selectedAccountId = accountId
        if let snapshot = snapshotsByAccount[accountId] {
            self.snapshot = snapshot
        } else {
            snapshot = nil
        }
        updateUIStatus()
    }

    func refreshCurrentAccount(ideType: String = "ANTIGRAVITY") {
        guard let accountId = selectedAccountId else {
            errorMessage = "未选择账户"
            uiStatus = .refreshFailed("未选择账户")
            return
        }

        uiStatus = .refreshing
        errorMessage = nil

        Task {
            do {
                let (id, freshSnapshot) = try await pollingService.refreshQuota(forAccountId: accountId, ideType: ideType)
                snapshotsByAccount[id] = freshSnapshot
                snapshot = freshSnapshot
                uiStatus = .refreshSuccess
                errorMessage = nil
            } catch let error as QuotaApiError {
                if error.needsReauth {
                    uiStatus = .reauthRequired
                    errorMessage = userFriendlyMessage(for: error)
                } else {
                    uiStatus = .refreshFailed(error.localizedDescription)
                    errorMessage = userFriendlyMessage(for: error)
                }
            } catch let error as GoogleOAuthError {
                if case .noActiveAccount = error {
                    uiStatus = .reauthRequired
                    errorMessage = "请先登录 Google 账户"
                } else {
                    uiStatus = .refreshFailed(error.localizedDescription)
                    errorMessage = error.localizedDescription
                }
            } catch {
                uiStatus = .refreshFailed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshAllAccounts(ideType: String = "ANTIGRAVITY") {
        uiStatus = .refreshing
        errorMessage = nil

        Task {
            do {
                let latest = try await pollingService.refreshAllAccountsQuota(ideType: ideType)
                snapshotsByAccount = latest
                if selectedAccountId == nil {
                    selectedAccountId = latest.keys.sorted().first
                }
                snapshot = snapshotsByAccount[selectedAccountId ?? ""]
                uiStatus = .refreshSuccess
                errorMessage = nil
            } catch let error as QuotaApiError {
                if error.needsReauth {
                    uiStatus = .reauthRequired
                } else {
                    uiStatus = .refreshFailed(error.localizedDescription)
                }
                errorMessage = userFriendlyMessage(for: error)
            } catch let error as GoogleOAuthError {
                if case .noActiveAccount = error {
                    uiStatus = .reauthRequired
                    errorMessage = "请先登录 Google 账户"
                } else {
                    uiStatus = .refreshFailed(error.localizedDescription)
                    errorMessage = error.localizedDescription
                }
            } catch {
                uiStatus = .refreshFailed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    func startPolling(intervalSeconds: TimeInterval? = nil, defaultInterval: TimeInterval = 60, ideType: String = "ANTIGRAVITY") {
        guard !isPolling else { return }

        isPolling = true
        let interval = max(5, intervalSeconds ?? defaultInterval)
        pollingIntervalSeconds = interval

        pollingService.startPolling(intervalSeconds: interval, ideType: ideType, onUpdate: { [weak self] latest in
            guard let self else { return }
            self.snapshotsByAccount = latest
            if self.selectedAccountId == nil {
                self.selectedAccountId = latest.keys.sorted().first
            }
            self.snapshot = self.snapshotsByAccount[self.selectedAccountId ?? ""]
            self.updateUIStatus()
            self.errorMessage = nil
        }, onError: { [weak self] message in
            guard let self else { return }
            self.uiStatus = .refreshFailed(message)
            self.errorMessage = message
        })
    }

    func stopPolling() {
        pollingService.stopPolling()
        isPolling = false
        pollingIntervalSeconds = nil
        updateUIStatus()
    }

    var statusText: String {
        uiStatus.displayText
    }

    var displayedModels: [ModelQuotaInfo] {
        guard let snapshot else {
            return []
        }

        var models = snapshot.models
        if showExhaustedOnly {
            models = models.filter { $0.isExhausted }
        }

        switch sortOption {
        case .remainingAsc:
            models.sort { $0.remainingPercentage < $1.remainingPercentage }
        case .remainingDesc:
            models.sort { $0.remainingPercentage > $1.remainingPercentage }
        case .nameAsc:
            models.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }

        return models
    }

    var lastRefreshText: String {
        guard let snapshot else {
            return "-"
        }

        let elapsed = Date().timeIntervalSince(snapshot.timestamp)
        let relative: String
        switch elapsed {
        case ..<0:
            relative = "刚刚"
        case ..<60:
            relative = "\(Int(elapsed))秒前"
        case ..<3600:
            relative = "\(Int(elapsed / 60))分钟前"
        case ..<86400:
            relative = "\(Int(elapsed / 3600))小时前"
        default:
            relative = "\(Int(elapsed / 86400))天前"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let absolute = formatter.string(from: snapshot.timestamp)
        return "\(relative) (\(absolute))"
    }

    /// Whether the quota data may be stale (> 5 minutes since last refresh).
    var isStale: Bool {
        guard let snapshot else { return false }
        return Date().timeIntervalSince(snapshot.timestamp) > 300
    }

    var nextAutoRefreshTime: String? {
        guard isPolling,
              let pollingIntervalSeconds else {
            return nil
        }

        // Base next refresh on now + interval, since the polling loop
        // sleeps for the full interval after completing all account refreshes.
        let next = Date().addingTimeInterval(max(5, pollingIntervalSeconds))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let absolute = formatter.string(from: next)

        let secondsUntil = next.timeIntervalSinceNow
        if secondsUntil < 60 {
            return "\(absolute) (即将刷新)"
        } else if secondsUntil < 3600 {
            return "\(absolute) (约\(Int(secondsUntil / 60))分钟后)"
        } else {
            return absolute
        }
    }

    var diagnosticsSummary: [String: String] {
        var summary: [String: String] = [
            "quotaStatus": statusText,
            "isPolling": isPolling ? "true" : "false",
            "selectedAccountId": selectedAccountId ?? "",
            "snapshotAccountCount": String(snapshotsByAccount.count)
        ]

        if let snapshot {
            summary["activeTier"] = snapshot.tier
            summary["activeModelCount"] = String(snapshot.models.count)
            summary["activeLastRefresh"] = lastRefreshText
            if let nextAutoRefreshTime {
                summary["nextAutoRefreshTime"] = nextAutoRefreshTime
            }
            if let lowest = snapshot.models.min(by: { $0.remainingPercentage < $1.remainingPercentage }) {
                summary["lowestModel"] = lowest.modelId
                summary["lowestRemainingPercent"] = String(Int(lowest.remainingPercentage))
            }
            summary["exhaustedModelsExist"] = exhaustedModelsExist ? "true" : "false"
            if let nextReset = nextResetTime {
                summary["nextResetTime"] = nextReset
            }
        }

        return summary
    }

    private func updateUIStatus() {
        switch uiStatus {
        case .refreshing:
            return
        case .reauthRequired:
            return
        case .refreshFailed:
            return
        default:
            break
        }

        if isPolling {
            if isStale {
                uiStatus = .refreshSuccess // still polling, but data may be from last cycle
            } else {
                uiStatus = .refreshSuccess
            }
        } else if snapshot != nil {
            uiStatus = .hasCachedNotRefreshed
        } else {
            uiStatus = .notLoggedIn
        }
    }

    private func userFriendlyMessage(for error: QuotaApiError) -> String {
        switch error {
        case .unauthorized:
            return "认证已失效，请重新登录 Google 账户"
        case .rateLimited:
            return "请求过于频繁，稍后将自动重试"
        case .serverError:
            return "服务暂时不可用，请稍后重试"
        case .badRequest:
            return "请求失败，请检查账户状态或稍后重试"
        case .network:
            return "网络异常，请检查网络或代理设置"
        case .parse:
            return "接口返回无法解析，请稍后重试"
        }
    }
}
