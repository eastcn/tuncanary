import Foundation

/// 脱敏诊断摘要（“复制脱敏诊断摘要”按钮的内容）。
///
/// 包含：生成时间、应用版本、macOS 版本、总体状态和原因、各状态卡的结论与关键证据、
/// 各站点的类别、延迟和最近 5 次结果，以及最近的故障事件。VPN 站点只显示“已配置/未配置”。
public struct DiagnosticSummary: Sendable {
    /// 一个站点的诊断条目。
    public struct SiteEntry: Sendable, Equatable {
        public var site: Site
        /// 最近结果（旧 → 新，最多 5 次）。
        public var history: [SiteResult]
        /// 未探测时的说明，例如 “未连接 VPN”。
        public var skippedText: String?

        public init(site: Site, history: [SiteResult], skippedText: String? = nil) {
            self.site = site
            self.history = history
            self.skippedText = skippedText
        }

        public var latest: SiteResult? { history.last }
    }

    public var generatedAt: Date
    public var appVersion: String
    public var osVersion: String
    public var overall: OverallAssessment
    public var local: LocalAssessment?
    public var sites: [SiteEntry]
    public var intranetConfigured: Bool
    /// VPN 站点未探测时的说明（未配置、未连接 VPN 等）。
    public var intranetSkippedText: String?
    /// 是否配置了 Tailnet 子网目标。摘要中不写目标地址。
    public var tailnetConfigured: Bool
    /// Tailnet 子网未探测时的说明。
    public var tailnetSkippedText: String?
    /// 最近的故障事件（旧 → 新）。
    public var events: [FaultEvent]

    public init(
        generatedAt: Date,
        appVersion: String,
        osVersion: String,
        overall: OverallAssessment,
        local: LocalAssessment?,
        sites: [SiteEntry],
        intranetConfigured: Bool,
        intranetSkippedText: String? = nil,
        tailnetConfigured: Bool = false,
        tailnetSkippedText: String? = nil,
        events: [FaultEvent] = []
    ) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.overall = overall
        self.local = local
        self.sites = sites
        self.intranetConfigured = intranetConfigured
        self.intranetSkippedText = intranetSkippedText
        self.tailnetConfigured = tailnetConfigured
        self.tailnetSkippedText = tailnetSkippedText
        self.events = events
    }

    /// 由站点历史构造公开站点条目（VPN 站点和 Tailnet 子网另行传入）。
    public static func siteEntries(history: SiteHistory, sites: [Site] = SiteCatalog.defaultSites) -> [SiteEntry] {
        sites.filter { $0.isEnabled && !$0.group.isConditional }
            .map { SiteEntry(site: $0, history: history.recent(for: $0.id)) }
    }

    /// 渲染为纯文本，全文经过 `redactor`。
    public func render(redactor: Redactor, timeZone: TimeZone = .current) -> String {
        var lines: [String] = []
        lines.append("\(AppIdentity.displayName) 诊断摘要")
        lines.append("生成时间：\(DateText.format(generatedAt, timeZone: timeZone))")
        lines.append("应用版本：\(appVersion)")
        lines.append("macOS 版本：\(osVersion)")
        lines.append("总体状态：\(overall.statusText)")
        lines.append("首要原因：\(overall.primaryReason)")

        if !overall.reasons.isEmpty {
            lines.append("")
            lines.append("原因：")
            for reason in overall.reasons {
                lines.append("- [\(reason.severity.displayName)] \(reason.text)")
                if let hint = reason.hint { lines.append("  提示：\(hint)") }
            }
        }

        if let local {
            lines.append("")
            lines.append("状态卡：")
            for card in local.cards {
                lines.append("[\(card.severity.displayName)] \(card.title)：\(card.conclusion)")
                if let hint = card.hint { lines.append("  提示：\(hint)") }
                for item in card.evidence { lines.append("  · \(item)") }
                if let summary = card.dnsGuard {
                    for line in summary.lines(timeZone: timeZone) { lines.append("  \(line)") }
                    for event in summary.recentEvents {
                        lines.append("  · 守护进程事件 \(DateText.format(event.date, timeZone: timeZone))：\(event.text)")
                    }
                }
            }
            if !local.diagnosticNotes.isEmpty {
                lines.append("")
                lines.append("其他（不参与判定）：")
                for note in local.diagnosticNotes { lines.append("  · \(note)") }
            }
        }

        lines.append("")
        lines.append("站点：")
        for group in SiteGroup.publicGroups(for: sites.map(\.site)) {
            let entries = sites.filter { $0.site.group == group }
            guard !entries.isEmpty else { continue }
            lines.append(group.displayName)
            for entry in entries { lines.append("  " + Self.siteLine(entry)) }
        }
        var intranet = "VPN 站点：\(intranetConfigured ? "已配置" : "未配置")"
        if let entry = sites.first(where: { $0.site.group == .intranet }), entry.latest != nil {
            intranet += "；" + Self.siteLine(entry, includeName: false)
        } else if let skipped = intranetSkippedText {
            intranet += "（\(skipped)）"
        }
        lines.append(intranet)
        var tailnet = "Tailnet 子网：\(tailnetConfigured ? "已配置" : "未配置")"
        if let entry = sites.first(where: { $0.site.group == .tailnet }), entry.latest != nil {
            tailnet += "；" + Self.siteLine(entry, includeName: false)
        } else if tailnetConfigured, let skipped = tailnetSkippedText {
            tailnet += "（\(skipped)）"
        }
        lines.append(tailnet)

        if !events.isEmpty {
            lines.append("")
            lines.append("最近事件：")
            for event in events.suffix(Self.eventLimit) {
                lines.append("- \(DateText.format(event.date, timeZone: timeZone)) [\(event.displaySeverity.displayName)] \(event.text)")
            }
        }

        return redactor.redact(lines.joined(separator: "\n"))
    }

    /// 摘要中附带的最近事件条数。
    public static let eventLimit = 20

    /// 站点行：类别、延迟和最近 5 次结果。不包含 URL。
    static func siteLine(_ entry: SiteEntry, includeName: Bool = true) -> String {
        let name = includeName ? "\(entry.site.name)：" : ""
        guard let latest = entry.latest else {
            return name + (entry.skippedText ?? "尚未检测")
        }
        var text = name + latest.category.displayName
        if let latency = latest.medianLatency {
            text += "，\(LatencyFormat.milliseconds(latency))"
        }
        let history = entry.history.map(\.category.shortName).joined(separator: " / ")
        text += "；最近 \(entry.history.count) 次：\(history)"
        return text
    }
}

/// 时间格式化（时区可注入，便于测试）。
public enum DateText {
    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// ISO 8601（JSON 输出）。
    public static func iso8601(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
