import Foundation

/// 状态卡种类。
public enum StatusCardKind: String, Sendable, Codable, CaseIterable {
    case proxyTun
    case vpn
    case primaryDNS
    case proxyDNS
    /// 只在存在 Tailscale 隧道或配置了家庭子网目标时出现。
    case tailnet

    /// 弹窗中的顺序：Clash TUN、VPN、主网络 DNS、Mihomo DNS、Tailnet。
    public static let displayOrder: [StatusCardKind] = [.proxyTun, .vpn, .primaryDNS, .proxyDNS, .tailnet]

    /// 同等严重程度下原因的排列优先级（越小越靠前），也用于命令行输出顺序。
    public var reasonPriority: Int {
        switch self {
        case .primaryDNS: return 0
        case .proxyTun: return 1
        case .proxyDNS: return 2
        case .vpn: return 3
        case .tailnet: return 4
        }
    }
}

/// 一张状态卡：严重程度、一句结论、提示和证据明细。
public struct StatusCard: Sendable, Equatable, Identifiable {
    public var kind: StatusCardKind
    /// 弹窗标题，例如 “Wi-Fi DNS”。
    public var title: String
    /// 文字行中的名称，例如 “主网络 DNS（Wi-Fi）”。
    public var label: String
    public var severity: Severity
    /// 一句结论，例如 “配置开启，utun1024 存在”。
    public var conclusion: String
    /// 处理提示（取自计划判定表的“提示”列），没有时为 nil。
    public var hint: String?
    /// 证据明细。
    public var evidence: [String]
    /// 黄或红时的故障键。
    public var faultKey: FaultKey?
    /// DNS 守护进程信息，只出现在主网络 DNS 卡，与本卡的判定分开展示。
    public var dnsGuard: DNSGuardSummary?

    public init(
        kind: StatusCardKind,
        title: String,
        label: String? = nil,
        severity: Severity,
        conclusion: String,
        hint: String? = nil,
        evidence: [String] = [],
        faultKey: FaultKey? = nil,
        dnsGuard: DNSGuardSummary? = nil
    ) {
        self.kind = kind
        self.title = title
        self.label = label ?? title
        self.severity = severity
        self.conclusion = conclusion
        self.hint = hint
        self.evidence = evidence
        self.faultKey = faultKey
        self.dnsGuard = dnsGuard
    }

    public var id: StatusCardKind { kind }

    /// 文字行，例如 “主网络 DNS（Wi-Fi）：VPN 已断开、TUN 运行中，DNS 未恢复为 223.5.5.5”。
    public var line: String {
        "\(label)：\(conclusion)"
    }

    /// 是否计入整体结论。Tailnet 卡的灰色表示“这个场景判断不了”（如在家时网段重叠），不拉低整体。
    public var countsTowardOverall: Bool {
        !(kind == .tailnet && severity == .unknown)
    }
}

/// Clash TUN 状态。
public enum TunState: Sendable, Equatable {
    /// 配置开启、verge-mihomo 运行、存在 fake-ip 网段内的 UP utun。
    case running(interface: String)
    /// 配置开启，但隧道接口不存在或 verge-mihomo 未运行。
    case inactive
    /// 配置关闭。
    case off
    /// 证据不足（配置不可读、缺字段或未采集）。
    case unknown

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// 汇总中的一条原因。
public struct AssessmentReason: Sendable, Equatable {
    public var severity: Severity
    /// 展示文本，例如 “主网络 DNS（Wi-Fi）：VPN 已断开、TUN 运行中，DNS 未恢复为 223.5.5.5”。
    public var text: String
    public var hint: String?
    public var faultKey: FaultKey?

    public init(severity: Severity, text: String, hint: String? = nil, faultKey: FaultKey? = nil) {
        self.severity = severity
        self.text = text
        self.hint = hint
        self.faultKey = faultKey
    }
}

/// 一轮本机评估结果。
public struct LocalAssessment: Sendable, Equatable {
    /// 四张卡中最严重的一项。
    public var severity: Severity
    /// 按弹窗顺序排列的四张状态卡。
    public var cards: [StatusCard]
    /// 黄或红的故障（宽限期内为空）。
    public var faults: [Fault]
    /// 首要原因（不含卡片名时的简短说法见 `reasons`）。
    public var primaryReason: String
    public var tunState: TunState
    public var vpnState: VPNConnectionState
    public var isInGracePeriod: Bool
    /// 是否启用内网站点探测（VPN 已连接时为 true）。
    public var intranetProbeEnabled: Bool
    /// 家庭子网探测决策。
    public var tailnetDecision: TailnetProbeDecision
    /// 主网络服务名，例如 “Wi-Fi”。
    public var primaryServiceName: String?
    /// Mihomo DNS 端口（来自配置）。
    public var mihomoDNSPort: Int?
    /// 只进诊断、不参与判定的信息（如 Tailscale 等其他隧道）。
    public var diagnosticNotes: [String]
    /// 可以作为“断开后预期 DNS”的当前保存值（系统解析已确认经过代理时才有），供设置页一键采用。
    public var learnableExpectedDNS: [String]?
    public var evaluatedAt: Date

    public init(
        severity: Severity,
        cards: [StatusCard],
        faults: [Fault],
        primaryReason: String,
        tunState: TunState,
        vpnState: VPNConnectionState,
        isInGracePeriod: Bool,
        intranetProbeEnabled: Bool,
        tailnetDecision: TailnetProbeDecision = .notConfigured,
        primaryServiceName: String?,
        mihomoDNSPort: Int?,
        diagnosticNotes: [String],
        learnableExpectedDNS: [String]? = nil,
        evaluatedAt: Date
    ) {
        self.severity = severity
        self.cards = cards
        self.faults = faults
        self.primaryReason = primaryReason
        self.tunState = tunState
        self.vpnState = vpnState
        self.isInGracePeriod = isInGracePeriod
        self.intranetProbeEnabled = intranetProbeEnabled
        self.tailnetDecision = tailnetDecision
        self.primaryServiceName = primaryServiceName
        self.mihomoDNSPort = mihomoDNSPort
        self.diagnosticNotes = diagnosticNotes
        self.learnableExpectedDNS = learnableExpectedDNS
        self.evaluatedAt = evaluatedAt
    }

    /// 故障键列表。
    public var faultKeys: [FaultKey] {
        faults.map(\.key)
    }

    public func card(_ kind: StatusCardKind) -> StatusCard? {
        cards.first { $0.kind == kind }
    }

    /// 非正常的卡片按严重程度（相同时按卡片优先级）排列成原因。不计入整体的卡片不列为原因。
    public var reasons: [AssessmentReason] {
        cards
            .filter { $0.severity != .ok && $0.countsTowardOverall }
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                return lhs.kind.reasonPriority < rhs.kind.reasonPriority
            }
            .map { AssessmentReason(severity: $0.severity, text: $0.line, hint: $0.hint, faultKey: $0.faultKey) }
    }
}
