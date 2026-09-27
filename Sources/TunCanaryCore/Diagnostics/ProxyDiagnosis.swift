import Foundation

/// mihomo 日志中的一条连接记录（`/logs` 推送的 payload）。
///
/// 两种格式：
/// - 匹配：`[TCP] 198.18.0.1:50141(curl) --> github.com:443 match DomainKeyword(github) using 节点选择[HK 01]`
/// - 拨号失败：`[TCP] dial 节点选择 (match DomainKeyword/github) 198.18.0.1:50141(curl) --> github.com:443 error: ...`
public struct ProxyLogConnection: Sendable, Equatable {
    /// `TCP` 或 `UDP`。
    public var network: String
    /// 来源地址（不含端口），例如 `198.18.0.1`、`127.0.0.1`。
    public var source: String
    /// 发起连接的进程名。
    public var process: String
    public var host: String
    public var port: Int
    /// 命中的规则，例如 `DomainKeyword(github)`。
    public var rule: String
    /// 出站链，例如 `节点选择[HK 01]`、`DIRECT`。
    public var chain: String
    /// 拨号失败时的错误；匹配记录为 nil。
    public var error: String?

    public init(network: String, source: String, process: String, host: String, port: Int,
                rule: String, chain: String, error: String? = nil) {
        self.network = network
        self.source = source
        self.process = process
        self.host = host
        self.port = port
        self.rule = rule
        self.chain = chain
        self.error = error
    }

    /// 出站链末端的节点名：`组[节点]` 取方括号内，没有方括号时取整串。
    public var node: String {
        guard chain.hasSuffix("]"), let open = chain.lastIndex(of: "[") else { return chain }
        return String(chain[chain.index(after: open)..<chain.index(before: chain.endIndex)])
    }

    /// 是否直连（不经节点）。
    public var isDirect: Bool {
        node == "DIRECT" || chain == "DIRECT"
    }

    /// 解析一条日志 payload；不是连接记录时返回 nil。
    public static func parse(_ payload: String) -> ProxyLogConnection? {
        guard let network = ["TCP", "UDP"].first(where: { payload.hasPrefix("[\($0)] ") }) else { return nil }
        var rest = String(payload.dropFirst(network.count + 3))
        if rest.hasPrefix("dial ") {
            // dial <组> (match <规则类型>/<内容>) <来源>(<进程>) --> <主机>:<端口> error: <错误>
            // 没有命中规则时没有括号部分：dial <组> <来源>(<进程>) --> ...
            rest.removeFirst(5)
            guard let errorRange = rest.range(of: " error: ") else { return nil }
            let head = String(rest[..<errorRange.lowerBound])
            let error = String(rest[errorRange.upperBound...])
            let chain: String
            let rule: String
            let endpoint: String
            if let matchRange = head.range(of: " (match "),
               let closeRange = head.range(of: ") ", range: matchRange.upperBound..<head.endIndex) {
                chain = String(head[..<matchRange.lowerBound])
                let raw = String(head[matchRange.upperBound..<closeRange.lowerBound])
                if let slash = raw.firstIndex(of: "/") {
                    rule = "\(raw[..<slash])(\(raw[raw.index(after: slash)...]))"
                } else {
                    rule = raw
                }
                endpoint = String(head[closeRange.upperBound...])
            } else {
                // 出站名和进程名都可能含空格，按“IPv4:端口(”定位来源地址。
                guard let match = sourcePattern.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
                      let chainRange = Range(match.range(at: 1), in: head),
                      let endpointRange = Range(match.range(at: 2), in: head) else { return nil }
                chain = String(head[chainRange])
                rule = ""
                endpoint = String(head[endpointRange])
            }
            guard let parts = parseEndpoint(endpoint) else { return nil }
            return ProxyLogConnection(network: network, source: parts.source, process: parts.process,
                                      host: parts.host, port: parts.port, rule: rule, chain: chain, error: error)
        }
        // <来源>(<进程>) --> <主机>:<端口> match <规则> using <链>
        guard let matchRange = rest.range(of: " match "),
              let usingRange = rest.range(of: " using ", range: matchRange.upperBound..<rest.endIndex),
              let parts = parseEndpoint(String(rest[..<matchRange.lowerBound])) else { return nil }
        return ProxyLogConnection(network: network, source: parts.source, process: parts.process,
                                  host: parts.host, port: parts.port,
                                  rule: String(rest[matchRange.upperBound..<usingRange.lowerBound]),
                                  chain: String(rest[usingRange.upperBound...]))
    }

    /// 出站名 + 空格 + `IPv4:端口(进程) --> ...`。第一组贪婪匹配，取最后一个符合的位置。
    private static let sourcePattern = try! NSRegularExpression(
        pattern: #"^(.*) (\d{1,3}(?:\.\d{1,3}){3}:\d+\(.*\) --> .*)$"#)

    /// `198.18.0.1:50141(curl) --> github.com:443`
    static func parseEndpoint(_ text: String) -> (source: String, process: String, host: String, port: Int)? {
        let sides = text.components(separatedBy: " --> ")
        guard sides.count == 2, let open = sides[0].firstIndex(of: "("), sides[0].hasSuffix(")") else { return nil }
        let sourceAddress = String(sides[0][..<open])
        let process = String(sides[0][sides[0].index(after: open)..<sides[0].index(before: sides[0].endIndex)])
        guard let sourceColon = sourceAddress.lastIndex(of: ":"),
              let targetColon = sides[1].lastIndex(of: ":"),
              let port = Int(sides[1][sides[1].index(after: targetColon)...]) else { return nil }
        return (String(sourceAddress[..<sourceColon]), process, String(sides[1][..<targetColon]), port)
    }
}

/// 一次站点失败诊断中，这次访问在代理里的走向。
public enum ProxyRoute: Sendable, Equatable {
    /// 在代理日志中找到了这次连接。`viaTun` 为 false 时表示经系统代理端口进入。
    case proxied(ProxyLogConnection, viaTun: Bool)
    /// 代理日志中没有这次连接：TUN 关闭时为直连；TUN 运行时说明连接没有进入代理。
    case notInProxy(tunRunning: Bool)
    /// 无法读取代理日志。
    case unavailable(reason: String)
}

/// 节点延迟测试结果。
public enum NodeDelay: Sendable, Equatable {
    case milliseconds(Int)
    case failed(reason: String)
}

/// 一次站点失败诊断：带观测复测一次的结果，以及这次访问在代理中的走向。只作证据，不参与判定。
public struct SiteDiagnosis: Sendable, Equatable {
    public var siteID: String
    public var siteName: String
    public var diagnosedAt: Date
    /// 是否由界面上的“诊断”按钮触发。
    public var manual: Bool
    /// 复测结果。
    public var outcome: RequestOutcome
    public var route: ProxyRoute
    /// 对命中节点测的延迟；直连、未找到连接或复测成功时为 nil。
    public var nodeDelay: NodeDelay?

    public init(siteID: String, siteName: String, diagnosedAt: Date, manual: Bool,
                outcome: RequestOutcome, route: ProxyRoute, nodeDelay: NodeDelay? = nil) {
        self.siteID = siteID
        self.siteName = siteName
        self.diagnosedAt = diagnosedAt
        self.manual = manual
        self.outcome = outcome
        self.route = route
        self.nodeDelay = nodeDelay
    }

    /// 展示用的几行说明。
    public var lines: [String] {
        var lines: [String] = []
        var result = "复测：\(outcome.category.displayName)"
        if let latency = outcome.latency, !outcome.category.countsAsFailure {
            result += " \(LatencyFormat.milliseconds(latency))"
        }
        if let detail = outcome.detail { result += "（\(detail)）" }
        lines.append(result)
        switch route {
        case .proxied(let connection, let viaTun):
            let path = viaTun ? "经 TUN" : "经系统代理"
            lines.append("代理：\(path)，规则 \(connection.rule) → \(connection.chain)")
            if let error = connection.error { lines.append("代理报错：\(error)") }
        case .notInProxy(let tunRunning):
            lines.append(tunRunning ? "代理：日志中没有这次连接，连接没有进入代理" : "代理：未经过代理（直连）")
        case .unavailable(let reason):
            lines.append("代理：无法读取代理日志（\(reason)）")
        }
        switch nodeDelay {
        case .milliseconds(let value)?: lines.append("节点延迟：\(value) ms")
        case .failed(let reason)?: lines.append("节点延迟：\(reason)")
        case nil: break
        }
        return lines
    }
}
