import Foundation

/// `--check` 的单次判定（纯函数）。
///
/// 单次运行没有历史，按计划替代“连续两轮”门槛：
/// - 本机结果为黄或红时，调用方等待 10 秒再采一次；两次一致（严重程度与故障键相同）才报告，否则判为未确认。
/// - 轻测中每个关键站点最多请求 2 次，两次都失败才算本次失败；失败站点按应用内告警规则映射，
///   因此“关键站点失败”为 1，“某分组关键站点全部失败”（百度；Google 与 Claude）为 2。
///   内网站点与应用一致按黄处理（见 docs/ARCHITECTURE.md）。
/// - 完整检测按每站 3 次请求的汇总类别判定失败，与应用的完整检测一致。
/// - 整体超时时保留已完成的本机评估与站点结果；未完成的站点标为“未完成（超时）”，不计为失败。
public struct CLIVerdict: Sendable, Equatable {
    /// 输出中的一行：标签（如 “[故障]”）与正文。
    public struct Line: Sendable, Equatable {
        public var tag: String
        public var text: String

        public init(tag: String, text: String) {
            self.tag = tag
            self.text = text
        }

        public var rendered: String { "\(tag) \(text)" }
    }

    public var severity: Severity
    public var exitCode: CLIExitCode
    public var checkedAt: Date
    public var full: Bool
    public var timedOut: Bool
    /// 本机检查是否完成了第一次评估；只有整体超时时可能为 false。
    public var localCompleted: Bool
    /// 本机结果是否确认（黄或红时两次采样一致）。
    public var localConfirmed: Bool
    /// 黄或红时的 10 秒复查是否因超时未完成。
    public var localRecheckMissing: Bool
    /// 报告用的状态卡（未确认时已降为灰）。
    public var cards: [StatusCard]
    public var siteResults: [SiteResult]
    /// 整体超时时尚未完成的站点，不计为失败。
    public var incompleteSites: [Site]
    /// 本次告警使用的公开站点配置。
    public var configuredSites: [Site]
    public var intranet: IntranetProbeDecision
    public var faults: [Fault]
    public var reasons: [AssessmentReason]

    public var primaryReason: String {
        reasons.first?.text ?? "各项检查正常"
    }

    // MARK: 判定

    public static func make(
        firstLocal: LocalAssessment,
        secondLocal: LocalAssessment?,
        siteResults: [SiteResult],
        intranet: IntranetProbeDecision,
        full: Bool,
        checkedAt: Date,
        configuredSites: [Site] = SiteCatalog.defaultSites
    ) -> CLIVerdict {
        build(firstLocal: firstLocal, secondLocal: secondLocal, siteResults: siteResults, incompleteSites: [],
              intranet: intranet, full: full, checkedAt: checkedAt, configuredSites: configuredSites, timedOut: false)
    }

    /// 整体超时（30 秒）：保留已完成的本机评估和站点结果，未完成的站点不计为失败。
    /// 退出码按已确认的结论计算，例如本机红色已确认仍返回 2；本机未完成或有关键站点未完成时，
    /// 其余结论正常也只判为未确认（3），不判为正常。
    public static func timedOut(
        firstLocal: LocalAssessment?,
        secondLocal: LocalAssessment?,
        siteResults: [SiteResult],
        incompleteSites: [Site],
        intranet: IntranetProbeDecision,
        full: Bool,
        checkedAt: Date,
        configuredSites: [Site] = SiteCatalog.defaultSites
    ) -> CLIVerdict {
        build(firstLocal: firstLocal, secondLocal: secondLocal, siteResults: siteResults,
              incompleteSites: incompleteSites, intranet: intranet, full: full, checkedAt: checkedAt,
              configuredSites: configuredSites, timedOut: true)
    }

    /// 整体超时且没有任何结论：退出码 3。
    public static func timedOut(checkedAt: Date, full: Bool) -> CLIVerdict {
        timedOut(firstLocal: nil, secondLocal: nil, siteResults: [], incompleteSites: [], intranet: .notConfigured,
                 full: full, checkedAt: checkedAt)
    }

    private static func build(
        firstLocal: LocalAssessment?,
        secondLocal: LocalAssessment?,
        siteResults: [SiteResult],
        incompleteSites: [Site],
        intranet: IntranetProbeDecision,
        full: Bool,
        checkedAt: Date,
        configuredSites: [Site],
        timedOut: Bool
    ) -> CLIVerdict {
        var cards: [StatusCard]
        var localSeverity: Severity
        var localFaults: [Fault]
        var localConfirmed = true
        // 黄或红时复查因超时未完成，与两次采样不一致同样判为未确认，但文案区分。
        let recheckMissing = secondLocal == nil

        if let firstLocal = firstLocal, !firstLocal.severity.isAlerting {
            cards = firstLocal.cards
            localSeverity = firstLocal.severity
            localFaults = firstLocal.faults
        } else if let firstLocal = firstLocal,
                  let second = secondLocal,
                  second.severity == firstLocal.severity,
                  Set(second.faultKeys) == Set(firstLocal.faultKeys) {
            cards = second.cards
            localSeverity = second.severity
            localFaults = second.faults
        } else if let firstLocal = firstLocal {
            localConfirmed = false
            let latest = secondLocal ?? firstLocal
            let suffix = recheckMissing ? "（复查未完成，未确认）" : "（两次采样不一致，未确认）"
            cards = latest.cards.map { card in
                guard card.severity.isAlerting else { return card }
                var capped = card
                capped.severity = .unknown
                capped.conclusion = card.conclusion + suffix
                capped.hint = nil
                capped.faultKey = nil
                return capped
            }
            localSeverity = .unknown
            localFaults = []
        } else {
            // 本机检查未完成：没有本机结论。
            localConfirmed = false
            cards = []
            localSeverity = .unknown
            localFaults = []
        }

        let intranetEligible = intranet.site != nil
        var failing = Set<String>()
        for result in siteResults where result.site.isKey {
            if result.site.group == .intranet && !intranetEligible { continue }
            if siteFailed(result, full: full) { failing.insert(result.site.id) }
        }
        let context: FailureContext = full ? .fullCheck : .singleCheck
        let connectivity = ConnectivityTracker.faults(failingSiteIDs: failing, context: context,
                                                       sites: configuredSites)

        var reasons = cards
            .filter { $0.severity != .ok }
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                return lhs.kind.reasonPriority < rhs.kind.reasonPriority
            }
            .map { AssessmentReason(severity: $0.severity, text: $0.line, hint: $0.hint, faultKey: $0.faultKey) }
        if firstLocal != nil && !localConfirmed {
            let text = recheckMissing ? "本机复查未完成（超时），判为未确认" : "本机检查两次采样结果不一致，判为未确认"
            reasons.insert(AssessmentReason(severity: .unknown, text: text), at: 0)
        }
        if timedOut {
            reasons.insert(AssessmentReason(
                severity: .unknown,
                text: timeoutText(localCompleted: firstLocal != nil, siteResults: siteResults,
                                  incompleteSites: incompleteSites)), at: 0)
        }
        reasons += connectivity.map { AssessmentReason(severity: $0.severity, text: $0.message, faultKey: $0.key) }
        reasons = reasons.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.severity != rhs.element.severity { return lhs.element.severity > rhs.element.severity }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        // 未完成的关键站点没有结论：不计失败，但其余正常时不能判为正常。
        let pendingKey = incompleteSites.contains { $0.isKey } ? Severity.unknown : .ok
        let severity = Severity.worst([localSeverity, pendingKey] + connectivity.map(\.severity))
        return CLIVerdict(
            severity: severity,
            exitCode: CLIExitCode(severity: severity),
            checkedAt: checkedAt,
            full: full,
            timedOut: timedOut,
            localCompleted: firstLocal != nil,
            localConfirmed: localConfirmed,
            localRecheckMissing: firstLocal != nil && !localConfirmed && recheckMissing,
            cards: cards,
            siteResults: siteResults,
            incompleteSites: incompleteSites,
            configuredSites: configuredSites,
            intranet: intranet,
            faults: localFaults + connectivity.map(\.fault),
            reasons: reasons
        )
    }

    /// 超时说明，例如“检查超时（30 秒），未完成：Google、Claude（不计为失败）”。
    private static func timeoutText(localCompleted: Bool, siteResults: [SiteResult], incompleteSites: [Site]) -> String {
        var text = "检查超时（\(Int(PulseConstants.cliOverallTimeout)) 秒）"
        var pending: [String] = []
        if !localCompleted {
            pending.append(siteResults.isEmpty && incompleteSites.isEmpty ? "本机检查未完成，未开始站点检测" : "本机检查未完成")
        }
        if !incompleteSites.isEmpty {
            pending.append("未完成：\(incompleteSites.map(\.name).joined(separator: "、"))（不计为失败）")
        }
        if !pending.isEmpty { text += "，" + pending.joined(separator: "；") }
        return text
    }

    /// 站点未完成时的展示文本。
    public static let incompleteText = "未完成（超时）"

    /// 轻测要求至多两次请求都失败；完整检测使用三次请求的站点汇总类别。
    public static func siteFailed(_ result: SiteResult, full: Bool = false) -> Bool {
        if full { return result.isFailure }
        if result.attempts.isEmpty { return result.isFailure }
        return result.attempts.allSatisfy { $0.category.countsAsFailure }
    }

    // MARK: 纯文本

    /// 各项输出行（不含首行）。
    public var lines: [Line] {
        var lines: [Line] = []
        let unknownTag = "[\(Severity.unknown.displayName)]"
        if timedOut {
            lines.append(Line(tag: unknownTag, text: CLIVerdict.timeoutText(
                localCompleted: localCompleted, siteResults: siteResults, incompleteSites: incompleteSites)))
        }
        if localCompleted && !localConfirmed {
            lines.append(Line(tag: unknownTag,
                              text: localRecheckMissing ? "本机检查：复查未完成（超时）" : "本机检查：两次采样结果不一致"))
        }
        let ordered = cards.enumerated().sorted { lhs, rhs in
            if lhs.element.severity != rhs.element.severity { return lhs.element.severity > rhs.element.severity }
            if lhs.element.kind.reasonPriority != rhs.element.kind.reasonPriority {
                return lhs.element.kind.reasonPriority < rhs.element.kind.reasonPriority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        for card in ordered {
            lines.append(Line(tag: "[\(card.severity.displayName)]", text: card.line))
        }
        lines.append(contentsOf: siteLines)
        return lines
    }

    private var siteLines: [Line] {
        let intranetSkipped = intranet.skippedText
        let incomplete = CLIVerdict.incompleteText
        if full {
            var result: [Line] = []
            let allSites = siteResults.map(\.site) + incompleteSites
            for group in SiteGroup.publicGroups(for: allSites) + [.intranet] {
                let sites = siteResults.filter { $0.site.group == group }
                let pending = incompleteSites.filter { $0.group == group }
                if group == .intranet {
                    if let first = sites.first, intranet.site != nil {
                        result.append(Line(tag: tag(for: [first]), text: "\(group.displayName)：\(first.summaryText)"))
                    } else if !pending.isEmpty {
                        result.append(Line(tag: tag(for: [], pending: pending), text: "\(group.displayName)：\(incomplete)"))
                    } else if let skipped = intranetSkipped {
                        result.append(Line(tag: "[跳过]", text: "\(group.displayName)：\(skipped)"))
                    }
                    continue
                }
                guard !sites.isEmpty || !pending.isEmpty else { continue }
                let text = (sites.map { "\($0.site.name) \($0.summaryText)" } + pending.map { "\($0.name) \(incomplete)" })
                    .joined(separator: " / ")
                result.append(Line(tag: tag(for: sites, pending: pending), text: "\(group.displayName)：\(text)"))
            }
            return result
        }

        var segments: [String] = []
        var included: [SiteResult] = []
        let pendingPublic = incompleteSites.filter { $0.group != .intranet }
        let pendingIntranet = incompleteSites.filter { $0.group == .intranet }
        for result in siteResults where result.site.group != .intranet {
            segments.append("\(result.site.name) \(result.summaryText)")
            included.append(result)
        }
        segments += pendingPublic.map { "\($0.name) \(incomplete)" }
        if let intranetResult = siteResults.first(where: { $0.site.group == .intranet }), intranet.site != nil {
            segments.append("\(intranetResult.site.name) \(intranetResult.summaryText)")
            included.append(intranetResult)
        } else if let pending = pendingIntranet.first {
            segments.append("\(pending.name) \(incomplete)")
        } else if intranet != .notConfigured, let skipped = intranetSkipped {
            segments.append("内网站点 \(skipped)")
        }
        guard !segments.isEmpty else { return [] }
        return [Line(tag: tag(for: included, pending: incompleteSites), text: segments.joined(separator: " / "))]
    }

    /// 行标签：相关故障的严重程度；没有故障但有站点失败时为“需关注”（仅展示，不影响退出码）。
    /// 含未完成的关键站点时至少为“未确认”。
    private func tag(for sites: [SiteResult], pending: [Site] = []) -> String {
        let ids = Set(sites.map(\.site.id))
        let faultSeverity = Severity.worst(
            ConnectivityTracker.faults(
                failingSiteIDs: Set(sites.filter { CLIVerdict.siteFailed($0, full: full) }.map(\.site.id)),
                context: full ? .fullCheck : .singleCheck,
                sites: configuredSites)
            .filter { !Set($0.siteIDs).isDisjoint(with: ids) }
            .map(\.severity))
        var displayed = sites.contains { CLIVerdict.siteFailed($0, full: full) }
            ? max(faultSeverity, .warning) : faultSeverity
        if pending.contains(where: \.isKey) { displayed = max(displayed, .unknown) }
        return "[\(displayed.displayName)]"
    }

    /// 纯文本输出，全文经过 `redactor`。
    public func renderText(redactor: Redactor) -> String {
        var output = ["状态：\(severity.displayName)（退出码 \(exitCode.rawValue)）"]
        output += lines.map(\.rendered)
        return redactor.redact(output.joined(separator: "\n"))
    }

    // MARK: JSON

    struct JSONPayload: Encodable {
        struct Reason: Encodable {
            var severity: String
            var text: String
            var hint: String?
            var faultKey: String?
        }

        struct Item: Encodable {
            var kind: String
            var title: String
            var severity: String
            var conclusion: String
            var hint: String?
            var evidence: [String]
        }

        struct SiteItem: Encodable {
            var id: String
            var name: String
            var group: String
            var category: String
            var categoryText: String
            var latencyMs: Int?
            var failed: Bool
            var attempts: [String]
        }

        struct Intranet: Encodable {
            var configured: Bool
            var status: String
        }

        struct FaultItem: Encodable {
            var key: String
            var severity: String
            var message: String
        }

        struct PendingSite: Encodable {
            var id: String
            var name: String
            var group: String
        }

        var status: String
        var statusText: String
        var exitCode: Int32
        var checkedAt: String
        var mode: String
        var timedOut: Bool
        var localCompleted: Bool
        var localConfirmed: Bool
        var primaryReason: String
        var reasons: [Reason]
        var items: [Item]
        var sites: [SiteItem]
        /// 整体超时时未完成的站点（不计为失败）。
        var incompleteSites: [PendingSite]
        var intranet: Intranet
        var faults: [FaultItem]
    }

    /// JSON 输出（键排序、缩进），全部字符串经过 `redactor`。不含内网站点 URL。
    public func renderJSON(redactor: Redactor, timeZone: TimeZone = .current) -> String {
        let r = redactor.redact
        let intranetStatus: String
        switch intranet {
        case .probe: intranetStatus = "probed"
        case .notConfigured: intranetStatus = "notConfigured"
        case .vpnDisconnected: intranetStatus = "vpnDisconnected"
        case .vpnUnconfirmed: intranetStatus = "vpnUnconfirmed"
        }
        let payload = JSONPayload(
            status: severity.rawValue,
            statusText: severity.displayName,
            exitCode: exitCode.rawValue,
            checkedAt: DateText.iso8601(checkedAt, timeZone: timeZone),
            mode: full ? "full" : "light",
            timedOut: timedOut,
            localCompleted: localCompleted,
            localConfirmed: localConfirmed,
            primaryReason: r(primaryReason),
            reasons: reasons.map {
                JSONPayload.Reason(severity: $0.severity.rawValue, text: r($0.text),
                                   hint: $0.hint.map(r), faultKey: $0.faultKey?.rawValue)
            },
            items: cards.map {
                JSONPayload.Item(kind: $0.kind.rawValue, title: r($0.title), severity: $0.severity.rawValue,
                                 conclusion: r($0.conclusion), hint: $0.hint.map(r), evidence: $0.evidence.map(r))
            },
            sites: siteResults.map {
                JSONPayload.SiteItem(
                    id: $0.site.id, name: $0.site.name, group: $0.site.group.rawValue,
                    category: $0.category.rawValue, categoryText: $0.category.displayName,
                    latencyMs: $0.medianLatency.map { Int(($0 * 1000).rounded()) },
                    failed: CLIVerdict.siteFailed($0, full: full),
                    attempts: $0.attempts.map(\.category.rawValue))
            },
            incompleteSites: incompleteSites.map {
                JSONPayload.PendingSite(id: $0.id, name: $0.name, group: $0.group.rawValue)
            },
            intranet: JSONPayload.Intranet(configured: intranet != .notConfigured, status: intranetStatus),
            faults: faults.map {
                JSONPayload.FaultItem(key: $0.key.rawValue, severity: $0.severity.rawValue, message: r($0.message))
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
