import Foundation

/// 单次 HTTPS 请求（或 TCP 连接）的结果。
public struct RequestOutcome: Sendable, Equatable {
    public var category: ProbeCategory
    /// 收到 HTTP 响应时的状态码。
    public var httpStatus: Int?
    /// HTTP：fetchStart → responseStart（秒），只在收到 HTTP 响应时有意义；TCP：连接建立或被拒绝所用的时间。
    public var latency: TimeInterval?
    /// 错误说明（如 URLError 描述），仅用于展示。
    public var detail: String?

    public init(category: ProbeCategory, httpStatus: Int? = nil, latency: TimeInterval? = nil, detail: String? = nil) {
        self.category = category
        self.httpStatus = httpStatus
        self.latency = latency
        self.detail = detail
    }

    /// 收到 HTTP 响应。
    public static func http(status: Int, latency: TimeInterval?) -> RequestOutcome {
        RequestOutcome(category: ProbeCategory(httpStatus: status), httpStatus: status, latency: latency)
    }

    /// TCP 连接探测收到对端应答：连接建立，或端口拒绝连接（说明路径可达）。
    public static func tcpAnswered(latency: TimeInterval, refused: Bool) -> RequestOutcome {
        RequestOutcome(category: .reachable, latency: latency, detail: refused ? "端口拒绝连接，路径可达" : nil)
    }

    /// 未收到 HTTP 响应的失败。
    public static func failure(_ category: ProbeCategory, detail: String? = nil) -> RequestOutcome {
        RequestOutcome(category: category, detail: detail)
    }

    public var receivedResponse: Bool {
        httpStatus != nil
    }
}

/// 一个站点一次检测（1 或 3 次请求）的汇总结果。
public struct SiteResult: Sendable, Equatable {
    public var site: Site
    public var category: ProbeCategory
    /// 收到应答的请求的延迟中位数（秒）。
    public var medianLatency: TimeInterval?
    public var attempts: [RequestOutcome]
    public var checkedAt: Date

    public init(site: Site, category: ProbeCategory, medianLatency: TimeInterval?, attempts: [RequestOutcome], checkedAt: Date) {
        self.site = site
        self.category = category
        self.medianLatency = medianLatency
        self.attempts = attempts
        self.checkedAt = checkedAt
    }

    /// 是否计为告警失败。
    public var isFailure: Bool {
        category.countsAsFailure
    }

    /// 展示文本，例如 “可达 35 ms”“有响应（访问受限）”“超时”。
    public var summaryText: String {
        if category == .reachable, let latency = medianLatency {
            return "\(category.displayName) \(LatencyFormat.milliseconds(latency))"
        }
        return category.displayName
    }
}

/// 汇总一次检测中的多次请求。
public enum SiteAggregator {
    /// 可达次数达到一半（向上取整）即为可达：3 次中至少 2 次、1 次中 1 次、2 次中 1 次。
    /// 否则取出现最多的非可达类别；并列时取最近一次出现的。没有请求时记为连接失败。
    public static func aggregate(site: Site, outcomes: [RequestOutcome], checkedAt: Date) -> SiteResult {
        SiteResult(
            site: site,
            category: category(of: outcomes),
            medianLatency: medianLatency(outcomes),
            attempts: outcomes,
            checkedAt: checkedAt
        )
    }

    public static func category(of outcomes: [RequestOutcome]) -> ProbeCategory {
        guard !outcomes.isEmpty else { return .connectionFailure }
        let reachable = outcomes.filter { $0.category == .reachable }.count
        let needed = (outcomes.count + 1) / 2
        if reachable >= needed { return .reachable }

        var counts: [ProbeCategory: Int] = [:]
        var lastIndex: [ProbeCategory: Int] = [:]
        for (index, outcome) in outcomes.enumerated() where outcome.category != .reachable {
            counts[outcome.category, default: 0] += 1
            lastIndex[outcome.category] = index
        }
        let best = counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lastIndex[lhs.key, default: -1] < lastIndex[rhs.key, default: -1]
        }
        return best?.key ?? .reachable
    }

    /// 收到应答（HTTP 响应或 TCP 应答）的请求的延迟中位数。失败的请求没有延迟。
    public static func medianLatency(_ outcomes: [RequestOutcome]) -> TimeInterval? {
        median(outcomes.filter { $0.receivedResponse || $0.category == .reachable }.compactMap(\.latency))
    }

    /// 中位数；偶数个时取中间两个的平均值。
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
}

/// 每站保留最近 5 次结果（只在内存中，重启后清空）。
public struct SiteHistory: Sendable, Equatable {
    public let limit: Int
    /// siteID → 结果（旧 → 新）。
    public private(set) var results: [String: [SiteResult]]

    public init(limit: Int = PulseConstants.siteHistoryLimit) {
        self.limit = limit
        results = [:]
    }

    public mutating func record(_ result: SiteResult) {
        var list = results[result.site.id, default: []]
        list.append(result)
        if list.count > limit { list.removeFirst(list.count - limit) }
        results[result.site.id] = list
    }

    public mutating func record(_ batch: [SiteResult]) {
        for result in batch { record(result) }
    }

    /// 最近结果（旧 → 新）。
    public func recent(for siteID: String) -> [SiteResult] {
        results[siteID] ?? []
    }

    public func latest(for siteID: String) -> SiteResult? {
        results[siteID]?.last
    }

    public mutating func clear() {
        results = [:]
    }
}
