import Foundation

/// 一条待发送的通知。
public struct PendingNotification: Sendable, Equatable {
    public var key: FaultKey
    public var severity: Severity
    public var title: String
    public var body: String

    public init(key: FaultKey, severity: Severity, title: String, body: String) {
        self.key = key
        self.severity = severity
        self.title = title
        self.body = body
    }
}

/// 按故障键去重通知。
///
/// - 某个键进入黄或红时通知一次；灰色不通知，恢复也不通知。
/// - 由黄升级为红对应另一个键（如 `site.google` → `group.overseas`），会再通知一次。
/// - 某轮检查中不再出现的键被清除，之后同一故障才允许再次通知。
///
/// 调用约定：每轮传入当前全部活动故障（本机 + 连通性）；宽限期内不要调用，避免清除仍存在的故障键。
/// 通知开关关闭时仍应调用以维护状态，只是不发送返回的通知。
public struct NotificationDeduper: Sendable, Equatable {
    public private(set) var activeKeys: Set<FaultKey>

    public init() {
        activeKeys = []
    }

    /// 更新活动故障，返回应发送的通知（按严重程度降序）。
    /// `redactor` 会再过一遍通知正文，确保不含 VPN 站点 URL、私有 IP 与主目录路径。
    public mutating func update(with faults: [Fault], redactor: Redactor? = nil) -> [PendingNotification] {
        var current: [FaultKey: Fault] = [:]
        var order: [FaultKey] = []
        for fault in faults where fault.severity.isAlerting {
            if let existing = current[fault.key] {
                if fault.severity > existing.severity { current[fault.key] = fault }
            } else {
                current[fault.key] = fault
                order.append(fault.key)
            }
        }

        let newKeys = order.filter { !activeKeys.contains($0) }
        activeKeys = Set(current.keys)

        return newKeys
            .compactMap { current[$0] }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.severity != rhs.element.severity { return lhs.element.severity > rhs.element.severity }
                return lhs.offset < rhs.offset
            }
            .map { NotificationDeduper.notification(for: $0.element, redactor: redactor) }
    }

    /// 清空已通知的键。
    public mutating func reset() {
        activeKeys = []
    }

    static func notification(for fault: Fault, redactor: Redactor?) -> PendingNotification {
        var body = fault.message
        if let hint = fault.hint, !hint.isEmpty {
            body += "。\(hint)"
        }
        if let redactor { body = redactor.redact(body) }
        return PendingNotification(
            key: fault.key,
            severity: fault.severity,
            title: "\(AppIdentity.displayName)：\(fault.severity.displayName)",
            body: body
        )
    }
}
