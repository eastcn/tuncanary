import Foundation
import TunCanaryCore

/// 弹窗当前页面。
public enum PopoverRoute: String, Sendable, Equatable, CaseIterable {
    case main
    case settings
    case recovery
}

/// 检查进度。`nil`（见 `AppModel.checkProgress`）表示空闲。
public struct CheckProgress: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// 本机检查（周期由设置决定）。
        case local
        /// 后台轻测。
        case light
        /// 手动完整检测（立即复测）。
        case full
    }

    public var kind: Kind
    /// 已完成的站点数。
    public var completed: Int
    /// 站点总数；未知时为 0。
    public var total: Int

    public init(kind: Kind, completed: Int = 0, total: Int = 0) {
        self.kind = kind
        self.completed = completed
        self.total = total
    }

    /// 完成比例；总数未知时为 nil。
    public var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

/// 菜单栏图标状态：颜色取最近一次结果，检查进行中只叠加指示，不切换成灰色。
public struct MenuBarIconState: Sendable, Equatable {
    public var severity: Severity
    public var isChecking: Bool
    /// 悬停提示，取 `OverallAssessment.tooltip`。
    public var tooltip: String
    /// 辅助功能标签。
    public var accessibilityLabel: String

    public init(severity: Severity, isChecking: Bool, tooltip: String, accessibilityLabel: String) {
        self.severity = severity
        self.isChecking = isChecking
        self.tooltip = tooltip
        self.accessibilityLabel = accessibilityLabel
    }

    public init(overall: OverallAssessment, isChecking: Bool) {
        var label = "\(AppIdentity.displayName)：\(overall.statusText)"
        if isChecking { label += "，检查进行中" }
        self.init(severity: overall.severity, isChecking: isChecking, tooltip: overall.tooltip, accessibilityLabel: label)
    }
}

/// 最近 5 次结果中的一个标记。
public struct HistoryMark: Sendable, Equatable {
    /// nil 表示空位（尚无结果）。
    public var category: ProbeCategory?

    public init(category: ProbeCategory?) {
        self.category = category
    }

    public static let empty = HistoryMark(category: nil)

    public var isEmpty: Bool { category == nil }
    public var tone: StatusTone { category.map(StatusTone.init) ?? .neutral }
    /// 短名，例如 “可达”“超时”；空位为 “无”。
    public var label: String { category?.shortName ?? "无" }
}

/// 顶部总体状态。
public struct HeaderPresentation: Sendable, Equatable {
    public var severity: Severity
    /// “正常”“需关注”“故障”“未确认”或“切换中”。
    public var statusText: String
    public var tone: StatusTone
    /// 首要原因。
    public var reason: String
    /// 首要原因的处理提示（如“等待 VPN 完全断开后，关闭并重新开启 Clash TUN”）。
    public var hint: String?
    /// “最近检查 20:00:05”“尚未完成检查”等。
    public var checkedText: String
    /// 宽限期说明。
    public var graceText: String?
}

/// 一个站点行。
public struct SiteRowPresentation: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// 关键站点（参与告警计数）。
    public var isKey: Bool
    /// 可达性类别文字，或“尚未检测”“未验证”“未连接 VPN”等。
    public var statusText: String
    public var tone: StatusTone
    /// 延迟中位数，如 “35 ms”；没有时为 “—”。
    public var latencyText: String
    /// 错误原因（HTTP 状态码、连续失败次数等）。
    public var detailText: String?
    /// 最近 5 次（旧 → 新），不足时前面补空位。
    public var history: [HistoryMark]
    public var accessibilityText: String
}

/// 一个站点分组。
public struct SiteGroupPresentation: Sendable, Equatable, Identifiable {
    public var group: SiteGroup
    public var title: String
    public var rows: [SiteRowPresentation]
    public var id: SiteGroup { group }
}

/// 弹窗的格式化逻辑（纯函数，便于测试）。
public enum PopoverFormatter {
    /// 历史标记个数。
    public static let historySlots = PulseConstants.siteHistoryLimit
    /// 没有延迟时的占位。
    public static let noValue = "—"

    // MARK: 顶部

    public static func header(
        overall: OverallAssessment,
        lastCheckedAt: Date?,
        graceEndsAt: Date?,
        isChecking: Bool,
        now: Date,
        timeZone: TimeZone
    ) -> HeaderPresentation {
        let tone: StatusTone = overall.isSwitching && overall.severity == .unknown ? .neutral : StatusTone(overall.severity)
        let checked: String
        if let date = lastCheckedAt {
            checked = "最近检查 \(clockText(date, now: now, timeZone: timeZone))"
        } else {
            checked = isChecking ? "正在进行首次检查…" : "尚未完成检查"
        }
        var grace: String?
        if let end = graceEndsAt {
            grace = "网络切换中，\(clockText(end, now: now, timeZone: timeZone)) 后自动复查"
        } else if overall.isSwitching {
            grace = "网络切换中，宽限期结束后自动复查"
        }
        return HeaderPresentation(
            severity: overall.severity,
            statusText: overall.statusText,
            tone: tone,
            reason: overall.primaryReason,
            hint: overall.reasons.first?.hint,
            checkedText: checked,
            graceText: grace)
    }

    /// 时间：当天显示 “20:00:05”，否则 “9月25日 20:00”。
    public static func clockText(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm:ss" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    // MARK: 进度

    /// 进度文字，例如 “完整检测 4/10”。
    public static func progressText(_ progress: CheckProgress) -> String {
        let counts = progress.total > 0 ? " \(progress.completed)/\(progress.total)" : ""
        switch progress.kind {
        case .full: return "完整检测" + (counts.isEmpty ? "中…" : counts)
        case .light: return "轻测" + (counts.isEmpty ? "中…" : counts)
        case .local: return "本机检查中…"
        }
    }

    /// “立即复测”按钮文字：空闲 “立即复测”；手动复测中 “复测中 4/10”；其他检查 “检查中…”。
    public static func recheckTitle(_ progress: CheckProgress?) -> String {
        guard let progress else { return "立即复测" }
        switch progress.kind {
        case .full:
            return progress.total > 0 ? "复测中 \(progress.completed)/\(progress.total)" : "复测中…"
        case .light, .local:
            return "检查中…"
        }
    }

    // MARK: 状态卡

    /// 按弹窗顺序排列的四张状态卡；尚无结果时给出灰色占位。
    public static func cards(_ local: LocalAssessment?) -> [StatusCard] {
        guard let local else {
            return [
                StatusCard(kind: .proxyTun, title: "Clash TUN", severity: .unknown, conclusion: "尚未检查"),
                StatusCard(kind: .vpn, title: "VPN", severity: .unknown, conclusion: "尚未检查"),
                StatusCard(kind: .primaryDNS, title: "主网络 DNS", severity: .unknown, conclusion: "尚未检查"),
                StatusCard(kind: .proxyDNS, title: "Mihomo DNS", severity: .unknown, conclusion: "尚未检查"),
            ]
        }
        return StatusCardKind.displayOrder.compactMap { local.card($0) }
    }

    // MARK: 站点

    public static func latencyText(_ result: SiteResult?) -> String {
        guard let latency = result?.medianLatency else { return noValue }
        return LatencyFormat.milliseconds(latency)
    }

    /// 最近 `slots` 次结果（旧 → 新），不足时在前面补空位。
    public static func historyMarks(_ results: [SiteResult], slots: Int = historySlots) -> [HistoryMark] {
        let recent = results.suffix(slots).map { HistoryMark(category: $0.category) }
        return Array(repeating: .empty, count: max(0, slots - recent.count)) + recent
    }

    /// 末尾连续失败的次数（计为失败的类别）。
    public static func trailingFailures(_ results: [SiteResult]) -> Int {
        var count = 0
        for result in results.reversed() {
            guard result.isFailure else { break }
            count += 1
        }
        return count
    }

    /// 错误原因：4xx/5xx 给出状态码；失败时给出连续失败次数与多次请求的分布；单次请求附带错误说明。
    public static func errorDetail(_ results: [SiteResult], redactor: Redactor) -> String? {
        guard let latest = results.last, latest.category != .reachable else { return nil }
        var parts: [String] = []
        switch latest.category {
        case .restricted, .serverError:
            var codes: [Int] = []
            for code in latest.attempts.compactMap(\.httpStatus) where !codes.contains(code) {
                codes.append(code)
            }
            if !codes.isEmpty {
                parts.append("HTTP " + codes.map(String.init).joined(separator: " / "))
            }
        default:
            break
        }
        if latest.isFailure {
            let streak = trailingFailures(results)
            if streak >= 2 { parts.append("连续 \(streak) 次失败") }
        }
        if latest.attempts.count > 1 {
            var counts: [(ProbeCategory, Int)] = []
            for attempt in latest.attempts {
                if let index = counts.firstIndex(where: { $0.0 == attempt.category }) {
                    counts[index].1 += 1
                } else {
                    counts.append((attempt.category, 1))
                }
            }
            if counts.count > 1 || latest.category.countsAsFailure {
                let text = counts
                    .sorted { $0.1 > $1.1 }
                    .map { "\($0.0.shortName) ×\($0.1)" }
                    .joined(separator: "、")
                parts.append("\(latest.attempts.count) 次请求：\(text)")
            }
        } else if let detail = latest.attempts.first?.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !detail.isEmpty, parts.isEmpty || latest.isFailure {
            let redacted = redactor.redact(detail)
            parts.append(redacted.count > 40 ? String(redacted.prefix(39)) + "…" : redacted)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 一个站点行。`skippedText` 非空时表示本次未探测（VPN 站点）。
    public static func siteRow(site: Site, history: [SiteResult], skippedText: String? = nil,
                               redactor: Redactor = Redactor()) -> SiteRowPresentation {
        let marks = historyMarks(history)
        let status: String
        let tone: StatusTone
        let latency: String
        var detail: String?
        if let skippedText {
            status = skippedText
            tone = .neutral
            latency = noValue
        } else if let latest = history.last {
            status = latest.category.displayName
            tone = StatusTone(latest.category)
            latency = latencyText(latest)
            detail = errorDetail(history, redactor: redactor)
        } else {
            status = "尚未检测"
            tone = .neutral
            latency = noValue
        }
        let recent = history.suffix(historySlots).map(\.category.shortName)
        var spoken = "\(site.name)：\(status)"
        if latency != noValue { spoken += "，延迟 \(latency)" }
        if let detail { spoken += "，\(detail)" }
        if !recent.isEmpty { spoken += "，最近 \(recent.count) 次：\(recent.joined(separator: "、"))" }
        return SiteRowPresentation(
            id: site.id, name: site.name, isKey: site.isKey,
            statusText: status, tone: tone, latencyText: latency, detailText: detail,
            history: marks, accessibilityText: spoken)
    }

    /// VPN 站点未探测时的补充说明。
    public static func intranetNote(_ decision: IntranetProbeDecision) -> String? {
        switch decision {
        case .probe: return nil
        case .notConfigured: return "未配置 VPN 站点 URL，可在设置中填写"
        case .vpnDisconnected: return "VPN 断开时不探测，不计入故障"
        case .vpnUnconfirmed: return "VPN 状态未确认，暂不探测"
        }
    }

    /// Tailnet 子网未探测时的补充说明。
    public static func tailnetNote(_ decision: TailnetProbeDecision) -> String? {
        switch decision {
        case .probe, .notConfigured: return nil
        case .tailscaleDown: return "Tailscale 未连接时不探测，不计入故障"
        case .sameSubnet: return "目标在当前网络的网段内（例如人就在该局域网里），不经 Tailscale，不探测"
        case .routeUnavailable: return "子网路由没有指向 Tailscale，见 Tailnet 卡"
        case .unconfirmed: return "路由未确认，暂不探测"
        }
    }

    /// 按当前启用站点的分组展示；VPN 站点单独遵守 VPN 门槛，不显示 URL。
    /// Tailnet 子网只在配置了目标时显示，遵守 Tailnet 卡的路由判断。
    public static func siteGroups(history: SiteHistory, intranet decision: IntranetProbeDecision,
                                  tailnet: TailnetProbeDecision = .notConfigured,
                                  redactor: Redactor = Redactor(),
                                  sites: [Site] = SiteCatalog.defaultSites) -> [SiteGroupPresentation] {
        let conditional: [SiteGroup] = tailnet == .notConfigured ? [.intranet] : [.intranet, .tailnet]
        return (SiteGroup.publicGroups(for: sites) + conditional).map { group in
            let rows: [SiteRowPresentation]
            if group == .intranet {
                let results = history.recent(for: SiteCatalog.intranetID)
                if let site = decision.site {
                    rows = [siteRow(site: site, history: results, redactor: redactor)]
                } else {
                    let placeholder = Site(id: SiteCatalog.intranetID, name: "VPN 站点", group: .intranet,
                                           url: URL(string: "https://intranet.invalid/")!, isKey: true, inLightProbe: true)
                    var row = siteRow(site: placeholder, history: results, skippedText: decision.skippedText)
                    row.detailText = intranetNote(decision)
                    if let note = row.detailText { row.accessibilityText += "，\(note)" }
                    rows = [row]
                }
            } else if group == .tailnet {
                let results = history.recent(for: SiteCatalog.tailnetID)
                if let site = tailnet.site {
                    rows = [siteRow(site: site, history: results, redactor: redactor)]
                } else {
                    let placeholder = Site(id: SiteCatalog.tailnetID, name: "Tailnet 子网", group: .tailnet,
                                           url: URL(string: "tcp://192.0.2.1:1")!, isKey: true, inLightProbe: true)
                    var row = siteRow(site: placeholder, history: results, skippedText: tailnet.skippedText)
                    row.detailText = tailnetNote(tailnet)
                    if let note = row.detailText { row.accessibilityText += "，\(note)" }
                    rows = [row]
                }
            } else {
                rows = sites
                    .filter { $0.isEnabled && $0.group == group }
                    .map { siteRow(site: $0, history: history.recent(for: $0.id), redactor: redactor) }
            }
            return SiteGroupPresentation(group: group, title: group.displayName, rows: rows)
        }
    }

    // MARK: 手动恢复步骤

    /// 从恢复步骤中取出可复制的命令（`networksetup -getdnsservers <服务名>`）。
    public static func command(in step: String) -> String? {
        guard let start = step.range(of: "networksetup ") else { return nil }
        let tail = step[start.lowerBound...]
        let end = tail.firstIndex(where: { "，,。；;（(".contains($0) }) ?? tail.endIndex
        let command = tail[..<end].trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? nil : command
    }
}
