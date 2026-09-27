import Foundation

/// 主网络 DNS 卡中的守护进程信息。
///
/// 与卡片本身的判定分开展示：卡片的严重程度只反映 TunCanary 检测到的状态，
/// 这里只说明守护进程是否安装、最近一次做了什么，不产生故障键。
public struct DNSGuardSummary: Sendable, Equatable {
    public var installed: Bool
    /// 读取失败的原因；读取成功为 nil。
    public var failureReason: String?
    /// 最近一次运行。
    public var lastRun: DNSGuardEvent?
    /// 最近一次尝试写入；与 `lastRun` 相同时为 nil。
    public var lastWrite: DNSGuardEvent?
    /// 需要用户注意的事项，例如目标值与预期 DNS 不一致、配置不可读。
    public var notices: [String]
    /// 最近的事件（旧 → 新）。
    public var recentEvents: [DNSGuardEvent]

    public init(installed: Bool, failureReason: String? = nil, lastRun: DNSGuardEvent? = nil,
                lastWrite: DNSGuardEvent? = nil, notices: [String] = [], recentEvents: [DNSGuardEvent] = []) {
        self.installed = installed
        self.failureReason = failureReason
        self.lastRun = lastRun
        self.lastWrite = lastWrite
        self.notices = notices
        self.recentEvents = recentEvents
    }

    /// 状态卡中事件的条数上限。
    public static let eventLimit = 5

    /// “DNS 守护进程：已安装”等。
    public var statusText: String {
        if let failureReason { return "DNS 守护进程：状态未知（\(failureReason)）" }
        return "DNS 守护进程：\(installed ? "已安装" : "未安装")"
    }

    /// 最近一次运行的展示文本；从未运行时为“尚未运行”。
    public func lastRunText(timeZone: TimeZone = .current) -> String? {
        guard installed else { return nil }
        guard let lastRun else { return "最近一次：尚未运行" }
        return "最近一次（\(DateText.format(lastRun.date, timeZone: timeZone))）：\(lastRun.text)"
    }

    public func lastWriteText(timeZone: TimeZone = .current) -> String? {
        guard installed, let lastWrite else { return nil }
        return "最近写入（\(DateText.format(lastWrite.date, timeZone: timeZone))）：\(lastWrite.text)"
    }

    /// 最近一次运行的展示严重程度；没有记录时为灰。
    public var lastRunSeverity: Severity {
        lastRun?.outcome.severity ?? .unknown
    }

    /// 纯文本行（诊断摘要、命令行）。
    public func lines(timeZone: TimeZone = .current) -> [String] {
        var lines = [statusText]
        if let text = lastRunText(timeZone: timeZone) { lines.append(text) }
        if let text = lastWriteText(timeZone: timeZone) { lines.append(text) }
        lines += notices.map { "注意：\($0)" }
        return lines
    }

    /// 由采集结果和设置生成。未采集时为 nil（例如测试和不读取守护进程的调用方）。
    public static func make(_ collected: Collected<DNSGuardSnapshot>, settings: AppSettings,
                            now: Date, timeZone: TimeZone = .current) -> DNSGuardSummary? {
        let snapshot: DNSGuardSnapshot
        switch collected {
        case .notCollected:
            return nil
        case .failed(let reason):
            return DNSGuardSummary(installed: false, failureReason: reason)
        case .collected(let value):
            snapshot = value
        }
        guard snapshot.installed else { return DNSGuardSummary(installed: false) }

        var notices: [String] = []
        switch snapshot.config {
        case .notCollected:
            notices.append("未找到守护进程配置")
        case .failed(let reason):
            notices.append("无法读取守护进程配置：\(reason)")
        case .collected(let config):
            notices += configNotices(config, settings: settings)
        }

        let state = snapshot.state.value
        if case .failed(let reason) = snapshot.state {
            notices.append("无法读取守护进程状态：\(reason)")
        }
        if let state {
            if state.connectedTakeoverSuspended {
                notices.append("连接期接管已停用：写入过于频繁，VPN 客户端可能在反复改写 DNS。VPN 下次断开后恢复")
            }
            if let until = state.backoffUntil, until > now {
                notices.append("连续失败 \(state.consecutiveFailures) 次，\(DateText.format(until, timeZone: timeZone)) 前不再写入")
            }
        }
        let lastWrite = state?.lastWrite == state?.lastRun ? nil : state?.lastWrite
        return DNSGuardSummary(installed: true, lastRun: state?.lastRun, lastWrite: lastWrite, notices: notices,
                               recentEvents: Array(snapshot.recentEvents.suffix(eventLimit)))
    }

    /// 守护进程配置与应用设置的一致性。守护进程写入目标值，应用按设置检查，两者不一致时会误报或漏报。
    static func configNotices(_ config: DNSGuardConfigSummary, settings: AppSettings) -> [String] {
        var notices: [String] = []
        let target = config.targetDNS.joined(separator: "、")
        if settings.disconnectedDNSRule == .equals {
            if !DNSList.sameSet(config.targetDNS, settings.effectiveExpectedDNS) {
                let expected = settings.effectiveExpectedDNS.joined(separator: "、")
                notices.append("守护进程的目标 DNS 为 \(target)，与设置中的预期 DNS \(expected) 不一致")
            }
        } else {
            notices.append("守护进程会把 DNS 设为 \(target)，建议把“VPN 断开、TUN 运行时”设为“指定地址”")
        }
        if config.connectedTakeoverEnabled && settings.connectedDNSRule != .proxyTakeover {
            notices.append("守护进程已启用连接期接管，建议把“VPN 连接时”设为“\(ConnectedDNSRule.proxyTakeover.displayName)”")
        }
        return notices
    }
}
