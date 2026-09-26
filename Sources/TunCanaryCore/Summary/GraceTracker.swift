import Foundation

/// 网络变化事件的原因。
public enum NetworkChangeReason: String, Sendable, Codable {
    /// 系统网络配置变化（SCDynamicStore、NWPathMonitor）。
    case network
    /// 系统唤醒。
    case wake
    /// 即将睡眠（暂停定时器，不进入宽限期）。
    case sleep

    /// 网络变化和唤醒都进入宽限期。
    public var startsGracePeriod: Bool {
        self != .sleep
    }
}

/// 网络变化事件。
public struct NetworkChangeEvent: Sendable, Equatable {
    public var reason: NetworkChangeReason
    public var date: Date

    public init(reason: NetworkChangeReason, date: Date) {
        self.reason = reason
        self.date = date
    }
}

/// 宽限期跟踪（纯值类型，时间由调用方传入）。
public struct GraceTracker: Sendable, Equatable {
    public let duration: TimeInterval
    /// 最近一次进入宽限期的时间。
    public private(set) var lastChange: Date?
    public private(set) var lastReason: NetworkChangeReason?

    public init(duration: TimeInterval = PulseConstants.gracePeriod) {
        self.duration = duration
    }

    /// 记录网络变化或唤醒；新的变化会把宽限期顺延。返回是否进入（或延长）了宽限期。
    @discardableResult
    public mutating func noteChange(_ reason: NetworkChangeReason, at date: Date) -> Bool {
        guard reason.startsGracePeriod else { return false }
        if let last = lastChange, last > date { return false }
        lastChange = date
        lastReason = reason
        return true
    }

    @discardableResult
    public mutating func note(_ event: NetworkChangeEvent) -> Bool {
        noteChange(event.reason, at: event.date)
    }

    /// 宽限期结束时间；从未进入过时为 nil。
    public var graceEndsAt: Date? {
        lastChange.map { $0.addingTimeInterval(duration) }
    }

    /// `now` 是否处于宽限期内（左闭右开）。
    public func isInGracePeriod(at now: Date) -> Bool {
        guard let start = lastChange, let end = graceEndsAt else { return false }
        return now >= start && now < end
    }

    /// 剩余时间；不在宽限期内为 0。
    public func remaining(at now: Date) -> TimeInterval {
        guard isInGracePeriod(at: now), let end = graceEndsAt else { return 0 }
        return end.timeIntervalSince(now)
    }
}
