import Foundation

struct ProxyConfig: Codable, Equatable {
    struct Proxy: Codable, Equatable {
        var host: String
        var port: Int
        var type: String
    }

    struct FakeIP: Codable, Equatable {
        var enabled: Bool
        var cidr: String
    }

    struct Mitm: Codable, Equatable {
        var modelRoutingEnabled: Bool

        enum CodingKeys: String, CodingKey {
            case modelRoutingEnabled = "model_routing_enabled"
        }
    }

    var logLevel: String
    var dylibLogEnabled: Bool
    var proxy: Proxy
    var fakeIP: FakeIP
    var mitm: Mitm?

    enum CodingKeys: String, CodingKey {
        case logLevel = "log_level"
        case dylibLogEnabled = "dylib_log_enabled"
        case proxy
        case fakeIP = "fake_ip"
        case mitm
    }

    static let `default` = ProxyConfig(
        logLevel: "warn",
        dylibLogEnabled: false,
        proxy: .init(host: "127.0.0.1", port: 7897, type: "socks5"),
        fakeIP: .init(enabled: true, cidr: "198.18.0.0/15"),
        mitm: .init(modelRoutingEnabled: false)
    )
}
