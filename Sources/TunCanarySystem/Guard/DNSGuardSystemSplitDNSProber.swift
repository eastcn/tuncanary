import Darwin
import Foundation
import TunCanaryCore

/// 系统分域模式只核验用户已经安装的规则，不创建 resolver 文件，不修改代理配置。
public struct DNSGuardSystemSplitDNSProber: Sendable {
    public struct ReadError: Error, Sendable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    public typealias ReadFile = @Sendable (DNSGuardSplitDNSRule) -> Result<String, ReadError>
    public typealias LoadResolvers = @Sendable () async -> [Resolver]?
    public typealias Resolve = @Sendable (String) async -> CanaryResult
    public typealias DirectResolve = @Sendable (String, String) async -> DNSGuardProbeResult

    private let readFile: ReadFile
    private let loadResolvers: LoadResolvers
    private let resolve: Resolve
    private let directResolve: DirectResolve

    public init(readFile: @escaping ReadFile = { Self.readInstalledFile($0) },
                loadResolvers: @escaping LoadResolvers = { await Self.currentResolvers() },
                resolve: Resolve? = nil, directResolve: @escaping DirectResolve = { await Self.resolveDirectly(host: $0, server: $1) }) {
        self.directResolve = directResolve
        self.readFile = readFile
        self.loadResolvers = loadResolvers
        let resolver = SystemResolverCanary(timeout: 5)
        self.resolve = resolve ?? { await resolver.resolve(host: $0) }
    }

    public func probe(host: String, rules: [DNSGuardSplitDNSRule],
                      publicProbe: DNSGuardPublicProbe?) async -> DNSGuardProbeResult {
        guard !rules.isEmpty else { return .failed("未配置系统分域 DNS 规则") }
        if let problem = await configurationProblem(rules: rules, host: host) { return .failed(problem) }
        let answers: [IPv4]
        switch await resolve(host) {
        case .resolved(let values) where !values.isEmpty: answers = values
        default: return .failed("系统解析内网探针失败或无记录")
        }
        // 系统解析可能命中旧缓存；至少一个配置上游必须在本轮真实响应，并与系统答案相符。
        guard let rule = rules.filter({ $0.matches(host) }).max(by: { $0.domain.count < $1.domain.count }) else {
            return .failed("探针没有分域规则")
        }
        var upstreamAnswered = false
        for server in rule.servers {
            if case .answered(let current) = await directResolve(host, server),
               current.contains(where: { answers.contains($0) }) {
                upstreamAnswered = true
                break
            }
        }
        guard upstreamAnswered else { return .failed("分域 DNS 上游无响应或与系统答案不一致") }
        if let publicProbe {
            // 新名字避免沿用接管前的系统缓存，不向公网发送任何内网域名。
            let queryHost = "dns-guard-" + UUID().uuidString.lowercased() + "." + publicProbe.host
            switch await resolve(queryHost) {
            case .resolved(let values) where !values.isEmpty && values.allSatisfy(publicProbe.fakeIPRange.contains):
                break
            default: return .failed("公网系统解析未返回代理 fake-ip")
            }
        }
        // 查询期间 resolver 可能切换；不能用旧配置的答案放行新的网络设置。
        if let problem = await configurationProblem(rules: rules, host: host) { return .failed(problem) }
        return .answered(answers)
    }

    private func configurationProblem(rules: [DNSGuardSplitDNSRule], host: String) async -> String? {
        for rule in rules {
            switch readFile(rule) {
            case .failure(let error): return error.reason
            case .success(let text):
                if let problem = rule.fileProblem(text) { return problem }
            }
        }
        guard let resolvers = await loadResolvers() else { return "无法读取系统生效的 DNS 规则" }
        return DNSGuardSplitDNSVerifier.problem(rules: rules, resolvers: resolvers, host: host)
    }

    public static func resolveDirectly(host: String, server: String) async -> DNSGuardProbeResult {
        await Blocking.run {
            switch UDPDNSClient.query(host: server, port: 53, name: host, timeout: 2) {
            case .answered(_, let response) where response.responseCode == 0 && !response.isTruncated:
                return .answered(response.ipv4Answers)
            case .answered: return .failed("分域 DNS 上游返回失败或截断应答")
            case .timedOut, .refused: return .noResponse
            case .failed: return .failed("分域 DNS 上游查询失败")
            }
        }
    }

    public static func readInstalledFile(_ rule: DNSGuardSplitDNSRule) -> Result<String, ReadError> {
        guard rule.domain == DNSGuardSplitDNSRule.normalized(rule.domain),
              SettingsValidator.isValidHostName(rule.domain) else { return .failure(.init("分域 DNS 域名无效")) }
        let directory = "/etc/resolver"
        let path = directory + "/" + rule.domain
        for entry in [directory, path] {
            var info = stat()
            guard lstat(entry, &info) == 0, info.st_uid == 0,
                  info.st_mode & (S_IWGRP | S_IWOTH) == 0,
                  info.st_mode & S_IFMT == (entry == directory ? S_IFDIR : S_IFREG) else {
                return .failure(.init("分域 DNS 文件缺失、不是普通文件或权限不安全"))
            }
            if entry == path && info.st_size > 16_384 { return .failure(.init("分域 DNS 文件过大")) }
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .failure(.init("无法读取持久化分域 DNS 文件"))
        }
        return .success(text)
    }

    public static func currentResolvers() async -> [Resolver]? {
        let result = await CommandRunner().runAsync("/usr/sbin/scutil", ["--dns"], timeout: 3)
        guard result.succeeded, !result.outputTruncated else { return nil }
        return ScutilDNSParser.parse(result.outputText)
    }
}
