import Foundation
import TunCanaryCore

/// 合并同一轮检查产生的多条通知（计划“状态汇总与通知”）：
/// 标题取其中最严重的状态，正文逐条列出原因（按严重程度降序，同级保持原顺序）。
public enum NotificationMerger {
    /// - Returns: 空数组返回 nil；只有一条时原样返回；多条时合并为一条，
    ///   `key` 与 `severity` 取最严重的那条，正文每行形如 “[故障] 原因”。
    public static func merge(_ notifications: [PendingNotification]) -> PendingNotification? {
        guard let first = notifications.first else { return nil }
        guard notifications.count > 1 else { return first }

        let ordered = notifications.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.severity != rhs.element.severity { return lhs.element.severity > rhs.element.severity }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        let top = ordered[0]
        let body = ordered
            .map { "[\($0.severity.displayName)] \($0.body)" }
            .joined(separator: "\n")
        return PendingNotification(
            key: top.key,
            severity: top.severity,
            title: title(for: top.severity),
            body: body)
    }

    /// 标题：“TunCanary：<状态>”，与 `NotificationDeduper` 的单条通知一致。
    public static func title(for severity: Severity) -> String {
        "\(AppIdentity.displayName)：\(severity.displayName)"
    }
}
