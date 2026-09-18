import Foundation

/// 读取本机 JoyCode IDE 的登录态（ptKey / tenant）。
///
/// 登录凭证由 JoyCode IDE 登录流程签发，落盘在 VS Code 风格的
/// state.vscdb（SQLite）中：`ItemTable` 表 `key='JoyCoder.IDE'`，
/// value 为 JSON，`joyCoderUser.ptKey` / `joyCoderUser.tenant`。
/// 因此使用前提是本机已安装并登录过 JoyCode IDE；JoyCode 版本更新后
/// 重新点击「自动获取」即可刷新到新的 ptKey。
///
/// 实现上使用系统自带的 /usr/bin/sqlite3 CLI（macOS 内置，零依赖）。
struct JoyCodeCredentialService {

    struct Credentials {
        let ptKey: String
        let tenant: String
    }

    enum JoyCodeCredentialError: LocalizedError {
        case databaseNotFound
        case cliFailed(String)
        case keyNotFound
        case parseFailed

        var errorDescription: String? {
            switch self {
            case .databaseNotFound:
                return "未找到 JoyCode 登录数据库（state.vscdb），请先安装并登录 JoyCode IDE"
            case .cliFailed(let detail):
                return "读取 state.vscdb 失败：\(detail)"
            case .keyNotFound:
                return "数据库中没有 'JoyCoder.IDE' 记录，请先在 JoyCode IDE 中登录"
            case .parseFailed:
                return "登录记录解析失败（joyCoderUser.ptKey 缺失），请确认 JoyCode 已登录"
            }
        }
    }

    /// state.vscdb 的标准路径：~/Library/Application Support/JoyCode/User/globalStorage/
    static func stateDBURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/JoyCode/User/globalStorage/state.vscdb")
    }

    func readCredentials() throws -> Credentials {
        let dbURL = Self.stateDBURL()
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw JoyCodeCredentialError.databaseNotFound
        }
        let raw = try readItemTableValue(dbPath: dbURL.path, key: "JoyCoder.IDE")
        guard
            let data = raw.data(using: .utf8),
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let user = obj["joyCoderUser"] as? [String: Any],
            let ptKey = user["ptKey"] as? String,
            !ptKey.isEmpty
        else {
            throw JoyCodeCredentialError.parseFailed
        }
        return Credentials(ptKey: ptKey, tenant: (user["tenant"] as? String) ?? "")
    }

    /// 通过 sqlite3 CLI 从 ItemTable 读取指定 key 的 value 文本（单行 JSON）。
    private func readItemTableValue(dbPath: String, key: String) throws -> String {
        let sql = "SELECT value FROM ItemTable WHERE key='\(key)'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", dbPath, sql]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw JoyCodeCredentialError.cliFailed("无法启动 sqlite3：\(error.localizedDescription)")
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
            throw JoyCodeCredentialError.cliFailed(detail)
        }

        var value = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 防御：个别版本 value 可能带尾随空行
        if value.hasSuffix("\n") { value = String(value.dropLast()) }
        guard !value.isEmpty else {
            throw JoyCodeCredentialError.keyNotFound
        }
        return value
    }
}
