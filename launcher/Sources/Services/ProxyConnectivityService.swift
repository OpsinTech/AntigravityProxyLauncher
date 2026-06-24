import Foundation

/// Result of a proxy connectivity probe.
struct ProxyProbeResult {
    let reachable: Bool
    let handshakeOK: Bool
    let latencyMs: Double?
    let error: String?
    let proxyType: String
    let host: String
    let port: Int

    var summary: String {
        if !reachable {
            return "无法连接 \(host):\(port)"
        }
        if !handshakeOK {
            return "\(host):\(port) 端口可达，但 \(proxyType.uppercased()) 握手失败"
        }
        if let ms = latencyMs {
            return "\(proxyType.uppercased()) \(host):\(port) ✓ (\(String(format: "%.0f", ms))ms)"
        }
        return "\(proxyType.uppercased()) \(host):\(port) ✓"
    }

    var isOK: Bool { reachable && handshakeOK }
}

/// Lightweight proxy connectivity checker — no external dependencies.
struct ProxyConnectivityService {

    func probe(host: String, port: Int, type: String) -> ProxyProbeResult {
        let start = CFAbsoluteTimeGetCurrent()

        // 1. TCP connect
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            return ProxyProbeResult(reachable: false, handshakeOK: false,
                                    latencyMs: nil, error: "socket() failed",
                                    proxyType: type, host: host, port: port)
        }
        defer { close(sock) }

        // Set timeout
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        let connectTime = (CFAbsoluteTimeGetCurrent() - start) * 1000

        guard connectResult == 0 else {
            return ProxyProbeResult(reachable: false, handshakeOK: false,
                                    latencyMs: connectTime, error: String(cString: strerror(errno)),
                                    proxyType: type, host: host, port: port)
        }

        // 2. If SOCKS5, try a basic handshake
        let proxyLower = type.lowercased()
        if proxyLower == "socks5" || proxyLower == "socks" {
            let handshakeOK = socks5QuickCheck(sock: sock)
            let totalTime = (CFAbsoluteTimeGetCurrent() - start) * 1000
            return ProxyProbeResult(reachable: true, handshakeOK: handshakeOK,
                                    latencyMs: totalTime,
                                    error: handshakeOK ? nil : "SOCKS5 握手超时或拒绝",
                                    proxyType: type, host: host, port: port)
        }

        // For HTTP/other proxies, just TCP reachability is good enough
        return ProxyProbeResult(reachable: true, handshakeOK: true,
                                latencyMs: connectTime, error: nil,
                                proxyType: type, host: host, port: port)
    }

    /// Send SOCKS5 auth request (no-auth) and check response.
    private func socks5QuickCheck(sock: Int32) -> Bool {
        // Method negotiation: VER=5, NMETHODS=1, METHOD=0 (no auth)
        let authReq: [UInt8] = [0x05, 0x01, 0x00]
        let sent = send(sock, authReq, authReq.count, 0)
        guard sent == authReq.count else { return false }

        // Read 2-byte response
        var buf = [UInt8](repeating: 0, count: 2)
        let received = recv(sock, &buf, 2, 0)
        guard received == 2 else { return false }

        // VER=5, METHOD=0 (no auth accepted) or METHOD=0xFF (no acceptable method)
        return buf[0] == 0x05 && buf[1] == 0x00
    }
}
