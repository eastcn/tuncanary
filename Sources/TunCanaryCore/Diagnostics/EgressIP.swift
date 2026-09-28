import Foundation

/// 出口检测接口的响应格式。
public enum EgressResponseFormat: Sendable, Equatable {
    /// Cloudflare `/cdn-cgi/trace`：`key=value` 文本。
    case cloudflareTrace
    /// 淘宝 IP 库 `outGetIpInfo`：JSON，`code` 为 0 时 `data.ip` 为出口。
    case taobaoIPInfo
    case responseHeader
    case jsonField
}

/// 检测的是 TunCanary 自身访问指定域名时，该目标看到的 HTTP 出口。
///
/// 内置 Cloudflare trace、字节响应头和旧淘宝 IP 库；自定义项支持 trace 域名或 HTTPS 回显端点。
/// 原始值：内置关键字、旧小写域名或带 endpoint: 前缀的端点配置，与旧版保存的值兼容。
public struct EgressIPTarget: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public static let cloudflare = EgressIPTarget(builtIn: "cloudflare")
    public static let claude = EgressIPTarget(builtIn: "claude")
    public static let chatgpt = EgressIPTarget(builtIn: "chatgpt")
    public static let bytedance = EgressIPTarget(builtIn: "bytedance")
    public static let taobao = EgressIPTarget(builtIn: "taobao")
    /// 内置目标，按固定顺序检测。
    public static let builtIns: [EgressIPTarget] = [.cloudflare, .claude, .chatgpt, .taobao, .bytedance]
    /// 自定义目标最多几个。
    public static let maxCustom = 5

    private static let builtInKeys: Set<String> = ["cloudflare", "claude", "chatgpt", "taobao", "bytedance"]

    private init(builtIn: String) { rawValue = builtIn }

    /// 接受内置项的关键字，或一个有效域名（大小写不敏感）。
    public init?(rawValue: String) {
        if rawValue.hasPrefix("endpoint:"),
           let data = Data(base64Encoded: String(rawValue.dropFirst(9))),
           let endpoint = try? JSONDecoder().decode(EgressEndpoint.self, from: data), endpoint.isValid {
            self.rawValue = rawValue
            return
        }
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

    public static func endpoint(_ endpoint: EgressEndpoint) -> EgressIPTarget? {
        guard endpoint.isValid else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(endpoint) else { return nil }
        return EgressIPTarget(rawValue: "endpoint:" + data.base64EncodedString())
    }

    public var endpoint: EgressEndpoint? {
        guard rawValue.hasPrefix("endpoint:"), let data = Data(base64Encoded: String(rawValue.dropFirst(9))) else { return nil }
        return try? JSONDecoder().decode(EgressEndpoint.self, from: data)
    }

    public var isBuiltIn: Bool { Self.builtInKeys.contains(rawValue) }

    /// 与某个自定义域名相同的内置目标（例如填了 chatgpt.com）。
    public var matchingBuiltIn: EgressIPTarget? {
        isBuiltIn ? self : (endpoint == nil ? Self.builtIns.first { $0.host == host } : nil)
    }

    /// 访问的域名。
    public var host: String {
        if let endpoint { return endpoint.url.host ?? "" }
        switch rawValue {
        case "cloudflare": return "www.cloudflare.com"
        case "claude": return "claude.ai"
        case "chatgpt": return "chatgpt.com"
        case "taobao": return "ip.taobao.com"
        case "bytedance": return "perfops.byte-test.com"
        default: return rawValue
        }
    }

    public var displayName: String {
        if let endpoint { return endpoint.name }
        switch rawValue {
        case "cloudflare": return "Cloudflare"
        case "claude": return "Claude"
        case "chatgpt": return "ChatGPT"
        case "taobao": return "淘宝 IP 库"
        case "bytedance": return "字节检测 CDN"
        default: return rawValue
        }
    }

    public var format: EgressResponseFormat {
        if self == .bytedance { return .responseHeader }
        if let endpoint { return endpoint.method == .header ? .responseHeader : .jsonField }
        return self == .taobao ? .taobaoIPInfo : .cloudflareTrace
    }

    public var url: URL {
        if let endpoint { return endpoint.url }
        if self == .bytedance { return URL(string: "https://perfops.byte-test.com/500b-bench.jpg")! }
        switch format {
        case .taobaoIPInfo:
            return URL(string: "https://ip.taobao.com/outGetIpInfo?ip=myip&accessKey=alibaba-inc")!
        case .responseHeader, .jsonField, .cloudflareTrace:
            return URL(string: "https://\(host)/cdn-cgi/trace")!
        }
    }
}

public enum EgressIPVersion: String, Sendable, Equatable, Codable {
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"

    public var displayName: String { rawValue }
}

/// 失败类型不携带原始响应正文或本机网络配置。
public enum EgressIPFailure: Sendable, Equatable, Codable {
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
    case challenge
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
        case .challenge: return "目标返回安全验证，自动检测已暂停"
        case .serviceRejected: return "查询接口拒绝，可能请求过快"
        }
    }
}

/// 一次检查的即时结果；失败时不保留先前成功的 IP。
public struct EgressIPResult: Sendable, Equatable, Codable {
    public let target: EgressIPTarget
    public let checkedAt: Date
    public let ip: String?
    public let ipVersion: EgressIPVersion?
    public let location: String?
    public let failure: EgressIPFailure?
    public let retryAfter: Date?

    public init(
        target: EgressIPTarget, checkedAt: Date, ip: String?, ipVersion: EgressIPVersion?,
        location: String?, failure: EgressIPFailure?, retryAfter: Date? = nil
    ) {
        self.target = target
        self.checkedAt = checkedAt
        self.ip = ip
        self.ipVersion = ipVersion
        self.location = location
        self.failure = failure
        self.retryAfter = retryAfter
    }

    public var isSuccess: Bool { ip != nil && ipVersion != nil && failure == nil }
}

/// 单轮检测。调度、历史和频率限制由调用方管理；检测器不上传结果。
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

/// 自定义端点只发送无凭据的 HTTPS 请求，不执行脚本，不跟随重定向。
public struct EgressEndpoint: Codable, Hashable, Sendable {
    public enum Method: String, Codable, Sendable { case header, json }
    public var name: String
    public var url: URL
    public var method: Method
    /// 响应头名，或点分隔的 JSON 字段路径（例如 data.ip）。
    public var selector: String

    public init(name: String, url: URL, method: Method, selector: String) {
        self.name = name; self.url = url; self.method = method; self.selector = selector
    }
    public var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 60,
              url.scheme?.lowercased() == "https", let host = url.host,
              SettingsValidator.isValidHostName(host), url.user == nil, url.password == nil,
              url.fragment == nil, !selector.isEmpty, selector.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        if method == .header {
            return selector.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
        return selector.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }
        }
    }
}
