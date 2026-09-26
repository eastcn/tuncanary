import Foundation
import TunCanaryCore

/// 网络变化去抖（纯值类型，时间由调用方传入，便于注入时钟测试）。
///
/// 规则：
/// - 网络变化与唤醒合并为“一串”：距最后一次变化满 `quietInterval`（2 秒）后输出一个事件，
///   事件时间取这一串中第一次变化的时间；串内出现过唤醒时原因为 `.wake`，否则为 `.network`。
/// - 持续抖动时，最迟在第一次变化后 `maxDelay` 秒输出，避免一直不出事件。
/// - 睡眠立即输出（调用方要在系统睡下前暂停定时器），并丢弃尚未输出的一串。
/// - 睡眠通知后 `sleepSuppression` 秒内的网络变化视为入睡过程的副作用，忽略；
///   唤醒或超过该时长后恢复处理（兼容睡眠被取消、收不到唤醒通知的情况）。
public struct ChangeDebouncer: Sendable, Equatable {
    /// 尚未输出的一串变化。
    public struct Burst: Sendable, Equatable {
        public var reason: NetworkChangeReason
        public var firstDate: Date
        public var lastDate: Date
        /// 合并的原始变化次数。
        public var count: Int
    }

    public let quietInterval: TimeInterval
    public let maxDelay: TimeInterval
    public let sleepSuppression: TimeInterval
    public private(set) var burst: Burst?
    /// 最近一次睡眠通知的时间；唤醒后清空。
    public private(set) var sleepingSince: Date?

    /// 默认最长延迟（秒）。宽限期 10 秒从第一次变化算起，输出后至少还剩 4 秒。
    public static let defaultMaxDelay: TimeInterval = 6
    /// 默认睡眠抑制时长（秒）。
    public static let defaultSleepSuppression: TimeInterval = 30

    public init(
        quietInterval: TimeInterval = PulseConstants.eventDebounce,
        maxDelay: TimeInterval = ChangeDebouncer.defaultMaxDelay,
        sleepSuppression: TimeInterval = ChangeDebouncer.defaultSleepSuppression
    ) {
        self.quietInterval = max(0, quietInterval)
        self.maxDelay = max(self.quietInterval, maxDelay)
        self.sleepSuppression = max(0, sleepSuppression)
    }

    /// 记录一次原始变化。睡眠立即返回事件；其他返回 nil，等到 `deadline` 调用 `fire`。
    @discardableResult
    public mutating func record(_ reason: NetworkChangeReason, at date: Date) -> NetworkChangeEvent? {
        switch reason {
        case .sleep:
            burst = nil
            sleepingSince = date
            return NetworkChangeEvent(reason: .sleep, date: date)
        case .wake:
            sleepingSince = nil
            merge(.wake, at: date)
            return nil
        case .network:
            if let since = sleepingSince {
                let elapsed = date.timeIntervalSince(since)
                if elapsed >= 0 && elapsed < sleepSuppression { return nil }
                sleepingSince = nil
            }
            merge(.network, at: date)
            return nil
        }
    }

    /// 当前一串应输出的时间；没有待输出的变化时为 nil。
    public var deadline: Date? {
        guard let burst else { return nil }
        let quietEnd = burst.lastDate.addingTimeInterval(quietInterval)
        let latest = burst.firstDate.addingTimeInterval(maxDelay)
        return min(quietEnd, latest)
    }

    /// 到时检查：`now` 不早于 `deadline` 时输出事件并清空。
    public mutating func fire(at now: Date) -> NetworkChangeEvent? {
        guard let burst, let deadline, now >= deadline else { return nil }
        self.burst = nil
        return NetworkChangeEvent(reason: burst.reason, date: burst.firstDate)
    }

    /// 清空全部状态（停止监听时调用）。
    public mutating func reset() {
        burst = nil
        sleepingSince = nil
    }

    private mutating func merge(_ reason: NetworkChangeReason, at date: Date) {
        guard var current = burst else {
            burst = Burst(reason: reason, firstDate: date, lastDate: date, count: 1)
            return
        }
        if reason == .wake { current.reason = .wake }
        current.firstDate = min(current.firstDate, date)
        current.lastDate = max(current.lastDate, date)
        current.count += 1
        burst = current
    }
}
