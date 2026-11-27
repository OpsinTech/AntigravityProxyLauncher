import Foundation

/// 管理「本地 SNI 分流器」LaunchDaemon。
///
/// Gemini 这类原生 Swift App 用 Network.framework 在框架内部建连，dyld 的 connect
/// hook 拿不到流量、系统代理也不认；唯一可靠的接管点是 getaddrinfo —— dylib 把这些
/// 进程的域名解析到 127.0.0.1，再由这个 root 守护进程按 TLS ClientHello 的 SNI 还原
/// 目标域名，经上游 SOCKS5 做纯隧道转发（不解密、不签证书）。
///
/// 二进制必须放在 `/Library/PrivilegedHelperTools`（root:wheel 755）。放在用户可写
/// 目录里会让任何能写该文件的进程获得 root 执行权。
final class SNIRedirectService {

    static let label = "com.antigravity.sniredirect"
    static let helperName = "com.antigravity.sniredirect"
    static let helperPath = "/Library/PrivilegedHelperTools/\(helperName)"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    static let port = 443

    enum Status: String {
        case running                 // 已安装且正在监听
        case installedNotRunning     // 已安装但没跑起来
        case portOccupied            // 443 被别的程序占用
        case notInstalled            // 没装

        var needsInstall: Bool { self != .running }
    }

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - 状态

    func status() -> Status {
        guard FileManager.default.fileExists(atPath: Self.helperPath),
              FileManager.default.fileExists(atPath: Self.plistPath) else {
            return .notInstalled
        }

        // 不能再用 lsof 判断：守护进程以 root 运行，普通用户的 lsof 看不到它的
        // 监听套接字，结果永远是「未运行」→ Gemini tab 一直提示需要修复。
        // 改成直接 connect 探测；「是不是我们」由 launchd 状态推断。
        let running = Self.isDaemonRunning()
        let listening = Self.canConnectToPort()

        if running && listening { return .running }
        if !running && listening { return .portOccupied }
        return .installedNotRunning
    }

    /// 直接对 127.0.0.1:443 发起 TCP 连接，成功即视为有服务在监听。
    static func canConnectToPort() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// 443 是否有监听者。`byUs == true` 时要求监听者确实是我们的守护进程。
    static func isPortListening(byUs: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return byUs ? out.contains("sni_redirect") || out.contains(helperName) : true
    }

    /// 守护进程是否处于 launchd 的 running 状态。
    static func isDaemonRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "system/\(label)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.contains("state = running")
    }

    // MARK: - 安装

    /// 已就绪则直接返回；否则弹一次管理员授权完成安装。
    func installIfNeeded(onProgress: ((String) -> Void)? = nil) throws {
        let status = self.status()

        if status == .portOccupied {
            throw InstallError(message: "127.0.0.1:\(Self.port) 已被其它程序占用，无法安装本地 SNI 分流器。请先释放该端口。")
        }

        if status == .running {
            // 「在跑」不等于「是当前配置」。两种情况都必须重装：
            //   1) 二进制变了 —— Launcher 升级后要换 helper；
            //   2) plist 里的 -socks5 还是旧端口 —— 用户改了上游代理后，
            //      守着旧端口的守护进程会让 Gemini 直接连不上网。
            if Self.helperNeedsUpgrade() {
                onProgress?("本地 SNI 分流器需要升级到当前版本（需要管理员授权一次）")
            } else if Self.plistUpstreamIsStale() {
                onProgress?("上游代理已变更，正在更新本地 SNI 分流器（需要管理员授权一次）")
            } else {
                onProgress?("本地 SNI 分流器已在运行")
                return
            }
        }

        guard let source = Self.bundledBinary() else {
            throw InstallError(message: "安装包内缺少 sni_redirect 二进制，请重新下载完整版本。")
        }
        onProgress?("安装本地 SNI 分流器（需要管理员授权一次）")
        try Self.runPrivileged(makeInstallScript(source: source.path))
        onProgress?("本地 SNI 分流器已启动")
    }

    /// app 包里的 sni_redirect（构建时随 Resources 一起打包）。
    static func bundledBinary() -> URL? {
        if let u = Bundle.main.url(forResource: "sni_redirect", withExtension: nil) { return u }
        // 开发态：仓库内 tools/sni_redirect/sni_redirect
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tools/sni_redirect/sni_redirect")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// root 守护进程的日志目录。不能用 /tmp：/tmp 全局可写，root 打开固定文件名
    /// 存在被预先放置符号链接、从而覆盖任意文件的攻击面。
    static let logDirectory = "/Library/Logs/AntigravityProxy"
    static let logPath = "\(logDirectory)/sni_redirect.log"
    static let errorLogPath = "\(logDirectory)/sni_redirect.err"

    /// 上游 SOCKS5 地址（从用户配置读取，不再硬编码 7897）。
    static func upstreamProxy() -> String {
        let config = (try? ProxyConfigService().loadForEditor()) ?? .default
        return "\(config.proxy.host):\(config.proxy.port)"
    }

    private func makeInstallScript(source: String) -> String {
        let upstream = Self.upstreamProxy()
        return """
        #!/bin/sh
        set -e
        /bin/mkdir -p /Library/PrivilegedHelperTools "\(Self.logDirectory)"
        /usr/sbin/chown root:wheel "\(Self.logDirectory)"
        /bin/chmod 755 "\(Self.logDirectory)"
        /usr/bin/install -m 755 -o root -g wheel \(Self.shellQuote(source)) \(Self.shellQuote(Self.helperPath))
        /bin/cat > \(Self.shellQuote(Self.plistPath)) <<'PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(Self.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(Self.helperPath)</string>
                <string>-listen</string><string>127.0.0.1:\(Self.port)</string>
                <string>-socks5</string><string>\(upstream)</string>
                <string>-log</string><string>\(Self.logPath)</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardOutPath</key><string>\(Self.logPath)</string>
            <key>StandardErrorPath</key><string>\(Self.errorLogPath)</string>
        </dict>
        </plist>
        PLIST
        /usr/sbin/chown root:wheel \(Self.shellQuote(Self.plistPath))
        /bin/chmod 644 \(Self.shellQuote(Self.plistPath))
        /bin/launchctl bootout system/\(Self.label) >/dev/null 2>&1 || true
        /bin/launchctl bootstrap system \(Self.shellQuote(Self.plistPath))
        """
    }

    /// 已装 plist 里的 `-socks5` 是否与当前配置的上游代理不一致。
    /// 读不到 plist 或解析不出参数时返回 false，避免因为读不到就无谓地弹授权。
    static func plistUpstreamIsStale() -> Bool {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = plist as? [String: Any],
            let args = dict["ProgramArguments"] as? [String],
            let idx = args.firstIndex(of: "-socks5"),
            idx + 1 < args.count
        else { return false }

        let installed = args[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        let desired = upstreamProxy().trimmingCharacters(in: .whitespacesAndNewlines)
        return installed != desired
    }

    /// 已安装的 helper 是否与随包分发的版本不同（按 SHA256 比较）。
    /// 比较不了时返回 false，避免因为读不到文件就无谓地弹一次授权。
    static func helperNeedsUpgrade() -> Bool {
        guard let bundled = bundledBinary(),
              let installedData = try? Data(contentsOf: URL(fileURLWithPath: helperPath)),
              let bundledData = try? Data(contentsOf: bundled)
        else { return false }
        return installedData != bundledData
    }

    /// 单引号转义：把 ' 变成 '\''，避免路径里的 $、反引号、引号在 root 权限下被执行。
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 用一次系统授权执行 root 脚本。
    private static func runPrivileged(_ script: String) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("antigravity-sni-install-\(UUID().uuidString).sh")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // 路径先按 AppleScript 字符串转义（反斜杠、双引号），再用 shell 单引号包裹，
        // 这样路径里的 $、反引号、空格都不会在 root 权限下被解释。
        let appleScriptSafe = tmp.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        p.arguments = ["-e", "do shell script \"sh '\(appleScriptSafe)'\" with administrator privileges"]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        try p.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? ""
            let detail = msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "退出码 \(p.terminationStatus)" : msg
            throw InstallError(message: "管理员授权失败或安装被取消: \(detail)")
        }
    }

    // MARK: - 卸载

    func uninstall() throws {
        let script = """
        #!/bin/sh
        /bin/launchctl bootout system/\(Self.label) >/dev/null 2>&1 || true
        /bin/rm -f "\(Self.plistPath)" "\(Self.helperPath)"
        """
        try Self.runPrivileged(script)
    }
}
