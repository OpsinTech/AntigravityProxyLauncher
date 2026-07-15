import Foundation

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum CommandRunnerError: Error {
    case executableNotFound(String)
    case nonZeroExit(CommandResult)
    case commandFailed(tool: String, message: String)
}

extension CommandRunnerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "可执行文件不存在: \(path)"
        case .nonZeroExit(let result):
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if stderr.isEmpty {
                return "命令执行失败，退出码: \(result.status)"
            }
            return "命令执行失败，退出码: \(result.status)，stderr: \(stderr)"
        case .commandFailed(let tool, let message):
            return "\(tool) 不可用: \(message)"
        }
    }
}

struct CommandRunner {
    static func run(_ executable: String, _ arguments: [String] = []) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CommandRunnerError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let result = CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )

        if result.status != 0 {
            throw CommandRunnerError.nonZeroExit(result)
        }

        return result
    }
}
