import Foundation

struct AccountStoreService {
    private struct AccountStorePayload: Codable {
        var activeAccountId: String?
        var accounts: [GoogleAccount]
    }

    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private var accountsFileURL: URL {
        FileSystemPaths.appSupportRoot.appendingPathComponent("accounts.json")
    }

    func loadAccounts() throws -> [GoogleAccount] {
        try loadStore().accounts
    }

    func saveAccount(_ account: GoogleAccount) throws {
        var store = try loadStore()
        if let index = store.accounts.firstIndex(where: { $0.id == account.id }) {
            store.accounts[index] = account
        } else {
            store.accounts.append(account)
        }

        if store.activeAccountId == nil {
            store.activeAccountId = account.id
        }

        try saveStore(store)
    }

    func deleteAccount(accountId: String) throws {
        var store = try loadStore()
        store.accounts.removeAll { $0.id == accountId }
        if store.activeAccountId == accountId {
            store.activeAccountId = store.accounts.first?.id
        }
        try saveStore(store)
    }

    func setActiveAccountId(_ accountId: String?) throws {
        var store = try loadStore()
        guard let accountId else {
            store.activeAccountId = nil
            try saveStore(store)
            return
        }

        let exists = store.accounts.contains { $0.id == accountId }
        if exists {
            store.activeAccountId = accountId
            store.accounts = store.accounts.map { account in
                var mutable = account
                mutable.isActive = (account.id == accountId)
                return mutable
            }
            try saveStore(store)
        }
    }

    func getActiveAccountId() throws -> String? {
        try loadStore().activeAccountId
    }

    func getActiveAccount() throws -> GoogleAccount? {
        let store = try loadStore()
        guard let activeId = store.activeAccountId else {
            return nil
        }
        return store.accounts.first { $0.id == activeId }
    }

    private func loadStore() throws -> AccountStorePayload {
        guard FileManager.default.fileExists(atPath: accountsFileURL.path) else {
            return AccountStorePayload(activeAccountId: nil, accounts: [])
        }
        let data = try Data(contentsOf: accountsFileURL)
        return try decoder.decode(AccountStorePayload.self, from: data)
    }

    private func saveStore(_ store: AccountStorePayload) throws {
        try FileSystemPaths.ensureRuntimeDirectoriesExist()
        let data = try encoder.encode(store)
        // Atomic write: write to temp file then replace, prevents corruption on crash
        let tempURL = accountsFileURL.appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        try? FileManager.default.removeItem(at: accountsFileURL)
        try FileManager.default.moveItem(at: tempURL, to: accountsFileURL)
    }
}
