import Foundation

/// 出口检测接口的响应格式。
public enum EgressResponseFormat: Sendable, Equatable {
    /// Cloudflare `/cdn-cgi/trace`：`key=value` 文本。
    case cloudflareTrace
    /// 淘宝 IP 库 `outGetIpInfo`：JSON，`code` 为 0 时 `data.ip` 为出口。
    case taobaoIPInfo
}

/// 检测的是 TunCanary 自身访问指定域名时，该目标看到的 HTTP 出口。
///
/// 内置 Cloudflare、Claude、ChatGPT 与淘宝，另可加入自定义域名。淘宝通过它的 IP 库接口获取，
/// 其余通过 `https://<域名>/cdn-cgi/trace` 获取，自定义域名只对经 Cloudflare 的站点有效。
/// 原始值：内置项为固定关键字，自定义项为小写域名；与旧版保存的值兼容。
public struct EgressIPTarget: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public static let cloudflare = EgressIPTarget(builtIn: "cloudflare")
    public static let claude = EgressIPTarget(builtIn: "claude")
    public static let chatgpt = EgressIPTarget(builtIn: "chatgpt")
    public static let taobao = EgressIPTarget(builtIn: "taobao")
    /// 内置目标，按固定顺序检测。
    public static let builtIns: [EgressIPTarget] = [.cloudflare, .claude, .chatgpt, .taobao]
    /// 自定义目标最多几个。
    public static let maxCustom = 5

    private static let builtInKeys: Set<String> = ["cloudflare", "claude", "chatgpt", "taobao"]

    private init(builtIn: String) { rawValue = builtIn }

    /// 接受内置项的关键字，或一个有效域名（大小写不敏感）。
    public init?(rawValue: String) {
        if Self.builtInKeys.contains(rawValue) {
            self.rawValue = rawValue
            return
        }
        let host = rawValue.lowercased()
        guard SettingsValidator.isValidHostName(host) else { return nil }
        self.rawValue = host
    }

    /// 由用户输入生成自定义目标：接受域名，也接受粘贴的 URL（只取主机名）。
    public static func custom(_ text: String) -> EgressIPTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = trimmed
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed), let parsed = url.host,
                  url.user == nil, url.password == nil else { return nil }
            host = parsed
        } else if let slash = trimmed.firstIndex(of: "/") {
            host = String(trimmed[..<slash])
        }
        guard !builtInKeys.contains(host) else { return nil }
        return EgressIPTarget(rawValue: host)
    }

    public var isBuiltIn: Bool { Self.builtInKeys.contains(rawValue) }

    /// 与某个自定义域名相同的内置目标（例如填了 chatgpt.com）。
    public var matchingBuiltIn: EgressIPTarget? {
        isBuiltIn ? self : Self.builtIns.first { $0.host == host }
    }

    /// 访问的域名。
    public var host: String {
        switch rawValue {
        case "cloudflare": return "www.cloudflare.com"
        case "claude": return "claude.ai"
        case "chatgpt": return "chatgpt.com"
        case "taobao": return "ip.taobao.com"
        default: return rawValue
        }
    }

    public var displayName: String {
        switch rawValue {
        case "cloudflare": return "Cloudflare"
        case "claude": return "Claude"
        case "chatgpt": return "ChatGPT"
        case "taobao": return "淘宝"
        default: return rawValue
        }
    }

    public var format: EgressResponseFormat {
        self == .taobao ? .taobaoIPInfo : .cloudflareTrace
    }

    public var url: URL {
        switch format {
        case .taobaoIPInfo:
            return URL(string: "https://ip.taobao.com/outGetIpInfo?ip=myip&accessKey=alibaba-inc")!
        case .cloudflareTrace:
            return URL(string: "https://\(host)/cdn-cgi/trace")!
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
    /// 查询接口返回了错误码（例如请求过快被限流）。
    case serviceRejected

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
        case .serviceRejected: return "查询接口拒绝，可能请求过快"
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
    /// 检测全部内置目标。
    public func check() async -> [EgressIPResult] {
        await check(targets: EgressIPTarget.builtIns)
    }
}
