import Foundation

/// 一条故障事件：监控启动，或某个故障键出现、严重程度变化、消失。
public struct FaultEvent: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        /// 监控启动。之后首次检查仍存在的故障会记为“出现”。
        case started
        case appeared
        /// 同一故障键的严重程度变化（黄 ↔ 红）。
        case changed
        /// 故障键不再处于黄或红：可能已恢复，也可能暂时无法确认。
        case cleared
    }

    public var date: Date
    public var kind: Kind
    /// `started` 为 nil。
    public var key: FaultKey?
    /// 出现、变化时为当前严重程度；消失时为消失前的严重程度；`started` 为 nil。
    public var severity: Severity?
    /// 已脱敏的故障描述；`started` 为空。
    public var message: String

    public init(date: Date, kind: Kind, key: FaultKey? = nil, severity: Severity? = nil, message: String = "") {
        self.date = date
        self.kind = kind
        self.key = key
        self.severity = severity
        self.message = message
    }

    /// 一行展示文本，例如 “出现：主网络 DNS（Wi-Fi）：……”。
    public var text: String {
        switch kind {
        case .started: return "开始监控"
        case .appeared: return "出现：\(message)"
        case .changed: return "变为\(severity?.displayName ?? "未知")：\(message)"
        case .cleared: return "消失（已恢复或无法确认）：\(message)"
        }
    }

    /// 展示用的严重程度：消失与启动显示为灰。
    public var displaySeverity: Severity {
        switch kind {
        case .appeared, .changed: return severity ?? .unknown
        case .started, .cleared: return .unknown
        }
    }
}

/// 比对前后两轮的活动故障，生成故障事件。
///
/// 调用约定与 `NotificationDeduper` 相同：每轮传入当前全部活动故障；宽限期内不要调用。
public struct FaultEventRecorder: Sendable, Equatable {
    public struct Active: Sendable, Equatable {
        public var severity: Severity
        public var message: String
    }

    public private(set) var active: [FaultKey: Active]

    public init() {
        active = [:]
    }

    /// 更新活动故障，返回本轮产生的事件：先是消失的（按键排序），再按 `faults` 的顺序给出出现和变化的。
    /// `redactor` 用于事件描述，写入日志的内容与通知一样经过脱敏。
    public mutating func update(with faults: [Fault], at date: Date, redactor: Redactor? = nil) -> [FaultEvent] {
        var current: [FaultKey: Active] = [:]
        var order: [FaultKey] = []
        for fault in faults where fault.severity.isAlerting {
            let message = redactor?.redact(fault.message) ?? fault.message
            if let existing = current[fault.key] {
                if fault.severity > existing.severity { current[fault.key] = Active(severity: fault.severity, message: message) }
            } else {
                current[fault.key] = Active(severity: fault.severity, message: message)
                order.append(fault.key)
            }
        }

        var events: [FaultEvent] = []
        for key in active.keys.sorted() where current[key] == nil {
            let previous = active[key]!
            events.append(FaultEvent(date: date, kind: .cleared, key: key, severity: previous.severity,
                                     message: previous.message))
        }
        for key in order {
            let now = current[key]!
            if let previous = active[key] {
                if previous.severity != now.severity {
                    events.append(FaultEvent(date: date, kind: .changed, key: key, severity: now.severity,
                                             message: now.message))
                }
            } else {
                events.append(FaultEvent(date: date, kind: .appeared, key: key, severity: now.severity,
                                         message: now.message))
            }
        }
        active = current
        return events
    }
}
