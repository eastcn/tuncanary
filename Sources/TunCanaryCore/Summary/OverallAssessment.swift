import Foundation

/// 总体状态：合并本机与连通性结果，取最严重的一项（红 > 黄 > 灰 > 绿）。
public struct OverallAssessment: Sendable, Equatable {
    public var severity: Severity
    /// 按严重程度排列的原因（同级时本机在前）。
    public var reasons: [AssessmentReason]
    /// 黄或红的故障（本机 + 连通性），供通知去重。
    public var faults: [Fault]
    /// 本机处于宽限期内。
    public var isSwitching: Bool

    public init(local: LocalAssessment?, connectivityFaults: [ConnectivityFault]) {
        var reasons: [AssessmentReason] = []
        var faults: [Fault] = []
        var severities: [Severity] = []

        if let local {
            severities.append(local.severity)
            if local.isInGracePeriod {
                reasons.append(AssessmentReason(severity: .unknown, text: "网络切换中"))
            }
            reasons.append(contentsOf: local.reasons.filter { !(local.isInGracePeriod && $0.severity == .unknown) })
            faults.append(contentsOf: local.faults)
            isSwitching = local.isInGracePeriod
        } else {
            severities.append(.unknown)
            reasons.append(AssessmentReason(severity: .unknown, text: "尚无检查结果"))
            isSwitching = false
        }

        for fault in connectivityFaults {
            severities.append(fault.severity)
            reasons.append(AssessmentReason(severity: fault.severity, text: fault.message, faultKey: fault.key))
            faults.append(fault.fault)
        }

        // 稳定排序：严重程度降序，同级保持原顺序。
        self.reasons = reasons.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.severity != rhs.element.severity { return lhs.element.severity > rhs.element.severity }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        self.faults = faults
        severity = Severity.worst(severities)
    }

    /// 首要原因，显示在弹窗顶部和悬停提示中。
    public var primaryReason: String {
        reasons.first?.text ?? "各项检查正常"
    }

    /// 状态文字：宽限期内且无更严重问题时显示“切换中”。
    public var statusText: String {
        if isSwitching && severity == .unknown { return "切换中" }
        return severity.displayName
    }

    /// 悬停提示：“TunCanary：<状态> — <首要原因>”。
    public var tooltip: String {
        "\(AppIdentity.displayName)：\(statusText) — \(primaryReason)"
    }

    public var faultKeys: [FaultKey] {
        faults.map(\.key)
    }
}
