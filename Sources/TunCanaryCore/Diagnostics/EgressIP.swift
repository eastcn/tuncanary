import Foundation

/// 检测的是 TunCanary 自身访问指定域名时，该目标看到的 HTTP 出口。
public enum EgressIPTarget: String, CaseIterable, Sendable, Equatable, Codable {
    case claude
    case cloudflare

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .cloudflare: return "Cloudflare"
        }
    }

    public var url: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/cdn-cgi/trace")!
        case .cloudflare: return URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!
        }
    }
}

public enum EgressIPVersion: String, Sendable, Equatable {
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"

    public var displayName: String { rawValue }
}

/// 失败类型不携带原始响应正文或本机网络配置。
public enum EgressIPFailure: Sendable, Equatable {
    case cancelled
    case timeout
    case redirect
    case httpStatus(Int)
    case invalidResponse
    case missingIP
    case invalidIP
    case bodyTooLarge
    case dnsFailure
    case tlsFailure
    case connectionFailure

    public var displayName: String {
        switch self {
        case .cancelled: return "检查已取消"
        case .timeout: return "请求超时"
        case .redirect: return "目标返回重定向"
        case .httpStatus(let status): return "HTTP \(status)"
        case .invalidResponse: return "响应格式无效"
        case .missingIP: return "响应缺少 IP"
        case .invalidIP: return "响应中的 IP 无效"
        case .bodyTooLarge: return "响应过大"
        case .dnsFailure: return "域名解析失败"
        case .tlsFailure: return "TLS 连接失败"
        case .connectionFailure: return "连接失败"
        }
    }
}

/// 一次检查的即时结果；失败时不保留先前成功的 IP。
public struct EgressIPResult: Sendable, Equatable {
    public let target: EgressIPTarget
    public let checkedAt: Date
    public let ip: String?
    public let ipVersion: EgressIPVersion?
    public let location: String?
    public let failure: EgressIPFailure?

    public init(
        target: EgressIPTarget, checkedAt: Date, ip: String?, ipVersion: EgressIPVersion?,
        location: String?, failure: EgressIPFailure?
    ) {
        self.target = target
        self.checkedAt = checkedAt
        self.ip = ip
        self.ipVersion = ipVersion
        self.location = location
        self.failure = failure
    }

    public var isSuccess: Bool { ip != nil && ipVersion != nil && failure == nil }
}

/// 仅由用户主动触发。实现不应轮询、持久化或上传检测结果。
public protocol EgressIPChecking: Sendable {
    /// 并发检测给定目标，结果按 `targets` 的顺序返回。
    func check(targets: [EgressIPTarget]) async -> [EgressIPResult]
}

extension EgressIPChecking {
    /// 检测全部目标。
    public func check() async -> [EgressIPResult] {
        await check(targets: EgressIPTarget.allCases)
    }
}
