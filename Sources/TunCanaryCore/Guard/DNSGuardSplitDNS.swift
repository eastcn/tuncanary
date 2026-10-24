import Foundation

/// 用户明确配置的系统分域规则；只接受普通的 53 端口 DNS。
public struct DNSGuardSplitDNSRule: Sendable, Equatable, Codable {
    public var domain: String
    public var servers: [String]

    public init(domain: String, servers: [String]) {
        self.domain = Self.normalized(domain)
        self.servers = DNSList.normalize(servers)
    }

    public static func normalized(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    public func matches(_ host: String) -> Bool {
        let host = Self.normalized(host)
        return host == domain || host.hasSuffix("." + domain)
    }

    /// 校验持久化文件，防止只在 VPN 连接期间临时出现的 resolver 被当成长期分域规则。
    public func fileProblem(_ text: String) -> String? {
        var nameservers: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let tokens = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let key = tokens.first else { continue }
            guard tokens.count == 2 else { return "分域 DNS 文件格式不受支持" }
            switch key {
            case "nameserver": nameservers.append(tokens[1])
            case "domain":
                if Self.normalized(tokens[1]) != domain { return "分域 DNS 文件的域名与配置不一致" }
            case "port":
                if tokens[1] != "53" { return "分域 DNS 使用了非标准端口" }
            case "timeout", "search_order":
                guard let value = Int(tokens[1]), value > 0 else { return "分域 DNS 文件参数无效" }
            default: return "分域 DNS 文件包含不支持的选项"
            }
        }
        return DNSList.sameSet(nameservers, servers) ? nil : "分域 DNS 文件的服务器与配置不一致"
    }
}

/// 只有已安装的规则、系统实际 resolver 和真实查询都通过，才允许接管默认 DNS。
public enum DNSGuardSplitDNSVerifier {
    public static func problem(rules: [DNSGuardSplitDNSRule], resolvers: [Resolver], host: String) -> String? {
        let global = resolvers.filter { !$0.isScoped }
        for rule in rules {
            let matching = global.filter { $0.domain.map(DNSGuardSplitDNSRule.normalized) == rule.domain }
            guard matching.count == 1, let resolver = matching.first else {
                return "系统分域 DNS 规则未生效或存在冲突"
            }
            guard resolver.port == nil || resolver.port == 53 else {
                return "系统分域 DNS 使用了非标准端口"
            }
            guard DNSList.sameSet(resolver.nameservers, rule.servers) else {
                return "系统分域 DNS 服务器与配置不一致"
            }
        }
        guard let expected = rules.filter({ $0.matches(host) }).max(by: { $0.domain.count < $1.domain.count }) else {
            return "探针未被配置的分域 DNS 规则覆盖"
        }
        let selected = global.filter { resolver in
            guard let domain = resolver.domain else { return false }
            return DNSGuardSplitDNSRule(domain: domain, servers: []).matches(host)
        }.max { ($0.domain?.count ?? 0) < ($1.domain?.count ?? 0) }
        guard selected?.domain.map(DNSGuardSplitDNSRule.normalized) == expected.domain else {
            return "探针被其他更具体的系统分域 DNS 规则覆盖"
        }
        return nil
    }
}

/// 默认 DNS 已接管后，公网查询必须经过代理，返回 fake-ip。
public struct DNSGuardPublicProbe: Sendable, Equatable {
    public var host: String
    public var fakeIPRange: IPv4CIDR

    public init(host: String, fakeIPRange: IPv4CIDR) {
        self.host = host
        self.fakeIPRange = fakeIPRange
    }
}
