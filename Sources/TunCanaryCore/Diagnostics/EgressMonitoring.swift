import Foundation

/// 设置使用 ISO 3166-1 编码，显示名称不参与告警比较。
public enum EgressRegions {
    public static let common = ["US", "JP", "SG", "TW", "CN", "HK"]
    public static let all = Locale.Region.isoRegions.map(\.identifier).filter {
        $0.count == 2 && $0.utf8.allSatisfy { (65...90).contains($0) }
    }.sorted()
    public static func name(_ code: String) -> String {
        let names = ["US": "美国", "JP": "日本", "SG": "新加坡", "TW": "中国台湾", "CN": "中国大陆", "HK": "中国香港"]
        return names[code] ?? Locale(identifier: "zh_Hans").localizedString(forRegionCode: code) ?? code
    }
}

public struct EgressMonitoringSettings: Codable, Equatable, Sendable {
    public var automatic = true
    public var interval: TimeInterval = 300
    public var notifyIPChanges = false
    /// 按实际目标身份多选；空集合表示只记录。
    public var allowedRegions: [String: Set<String>] = [:]
    public init() {}
    public var effectiveInterval: TimeInterval {
        interval.isFinite && interval >= 300 && interval <= 86400 ? interval : 300
    }
    public var isValid: Bool {
        interval == effectiveInterval && allowedRegions.values.allSatisfy { $0.isSubset(of: Set(EgressRegions.all)) }
    }
}

public struct EgressGeo: Codable, Equatable, Sendable {
    public var ip: String
    public var countryCode: String
    public var region: String
    public var city: String
    public var isp: String
    public var checkedAt: Date
    public var source: String
    public init(ip: String, countryCode: String, region: String = "", city: String = "", isp: String = "",
                checkedAt: Date, source: String = "ipwho.is") {
        self.ip = ip; self.countryCode = countryCode; self.region = region; self.city = city
        self.isp = isp; self.checkedAt = checkedAt; self.source = source
    }
    public func isFresh(at date: Date) -> Bool {
        date.timeIntervalSince(checkedAt) >= -60 && date.timeIntervalSince(checkedAt) < 7 * 86400
    }
    public var displayName: String {
        ([EgressRegions.name(countryCode)] + [region, city].filter { !$0.isEmpty }).joined(separator: " · ")
    }
}

public struct EgressGeoLookup: Sendable {
    public var geo: EgressGeo?
    public var retryAfter: Date?
    public init(geo: EgressGeo? = nil, retryAfter: Date? = nil) { self.geo = geo; self.retryAfter = retryAfter }
}

public protocol EgressGeoLookingUp: Sendable {
    func lookup(ip: String) async -> EgressGeoLookup
}

public struct EgressObservation: Codable, Equatable, Sendable {
    public var result: EgressIPResult
    public var geo: EgressGeo?
    public init(result: EgressIPResult, geo: EgressGeo? = nil) { self.result = result; self.geo = geo }
    public var regionIsFresh: Bool {
        guard result.isSuccess, let geo, geo.ip == result.ip, geo.isFresh(at: result.checkedAt) else { return false }
        if let loc = result.location {
            let code = String(loc.prefix(2)).uppercased()
            if EgressRegions.all.contains(code) && code != geo.countryCode { return false }
        }
        return true
    }
}

public struct EgressControl: Codable, Equatable, Sendable {
    public var nextAttempt: Date?
    public var lastAttempt: Date?
    public var failures = 0
    public var suspended = false
    public init() {}
}

public struct EgressRegionAlertState: Codable, Equatable, Sendable {
    public var rule: Set<String> = []
    public var violations = 0
    public var active = false
    public var lastSample: Date?
    public init() {}
}

public struct EgressAlert: Equatable, Sendable {
    public enum Kind: Sendable { case ipChanged, regionViolation, regionRecovered }
    public var target: EgressIPTarget
    public var kind: Kind
    public var countryCode: String?
}

/// 持久化采样、冷却与通知状态。重启不能绕过限流，也不能重复通知同一持续异常。
public struct EgressMonitorState: Codable, Equatable, Sendable {
    public var history: [EgressObservation] = []
    public var geoCache: [String: EgressGeo] = [:]
    public var geoNextAttempt: [String: Date] = [:]
    public var geoServiceNextAttempt: Date?
    public var controls: [String: EgressControl] = [:]
    public var regionAlerts: [String: EgressRegionAlertState] = [:]
    public init() {}

    public mutating func prune(at now: Date) {
        let cutoff = now.addingTimeInterval(-30 * 86400)
        history.removeAll { $0.result.checkedAt < cutoff || $0.result.checkedAt > now.addingTimeInterval(60) }
        // 10 个目标、5 分钟一次、30 天最多 86400 条；额外容量用于手动检测和迁移。
        if history.count > 100_000 { history = Array(history.suffix(100_000)) }
        geoCache = geoCache.filter { now.timeIntervalSince($0.value.checkedAt) <= 30 * 86400 }
        geoNextAttempt = geoNextAttempt.filter { $0.value > now }
    }

    public func isEligible(_ target: EgressIPTarget, at date: Date, interval: TimeInterval) -> Bool {
        let control = controls[target.rawValue] ?? EgressControl()
        if control.suspended { return false }
        let earliest = max(control.nextAttempt ?? .distantPast, (control.lastAttempt ?? .distantPast).addingTimeInterval(interval))
        return date >= earliest
    }

    public mutating func begin(_ target: EgressIPTarget, at date: Date) {
        var control = controls[target.rawValue] ?? EgressControl()
        control.lastAttempt = date
        controls[target.rawValue] = control
    }

    /// 人工恢复仍保留下一次允许请求的时间，不能通过按钮绕过 429。
    public mutating func resume(_ target: EgressIPTarget) {
        controls[target.rawValue]?.suspended = false
    }

    public mutating func record(_ observation: EgressObservation, settings: EgressMonitoringSettings) -> [EgressAlert] {
        let result = observation.result
        let key = result.target.rawValue
        let now = result.checkedAt
        let interval = settings.effectiveInterval
        let previous = history.last { $0.result.target == result.target && $0.result.isSuccess && $0.result.ipVersion == result.ipVersion }
        var alerts: [EgressAlert] = []
        if result.isSuccess, let previous, previous.result.ip != result.ip, settings.notifyIPChanges {
            alerts.append(EgressAlert(target: result.target, kind: .ipChanged))
        }
        var control = controls[key] ?? EgressControl()
        control.lastAttempt = control.lastAttempt ?? now
        if result.isSuccess {
            control.failures = 0
            control.nextAttempt = now.addingTimeInterval(interval)
        } else {
            control.failures = min(8, control.failures + 1)
            let backoff = min(6 * 3600, interval * pow(2, Double(control.failures - 1)))
            control.nextAttempt = max(now.addingTimeInterval(backoff), result.retryAfter ?? .distantPast)
            if result.failure == .httpStatus(403) || result.failure == .challenge { control.suspended = true }
        }
        controls[key] = control
        let allowed = settings.allowedRegions[key] ?? []
        var region = regionAlerts[key] ?? EgressRegionAlertState()
        if region.rule != allowed { region = EgressRegionAlertState(); region.rule = allowed }
        if let last = region.lastSample, now.timeIntervalSince(last) > interval * 1.5 { region.violations = 0 }
        region.lastSample = now
        if allowed.isEmpty || !observation.regionIsFresh {
            region.violations = 0
        } else if let code = observation.geo?.countryCode {
            if allowed.contains(code) {
                region.violations = 0
                if region.active { alerts.append(EgressAlert(target: result.target, kind: .regionRecovered, countryCode: code)) }
                region.active = false
            } else {
                region.violations = min(2, region.violations + 1)
                if region.violations >= 2 && !region.active {
                    alerts.append(EgressAlert(target: result.target, kind: .regionViolation, countryCode: code))
                    region.active = true
                }
            }
        }
        regionAlerts[key] = region
        history.append(observation)
        prune(at: now)
        return alerts
    }

    public func summary(for target: EgressIPTarget, at now: Date, interval: TimeInterval) -> EgressStabilitySummary {
        let samples = history.filter { $0.result.target == target }
        guard let latest = samples.last else { return EgressStabilitySummary() }
        let successful = samples.filter { $0.result.isSuccess }
        var previousByFamily: [EgressIPVersion: String] = [:]
        var changes = 0
        for item in successful {
            guard let family = item.result.ipVersion, let ip = item.result.ip else { continue }
            if let previous = previousByFamily[family], previous != ip { changes += 1 }
            previousByFamily[family] = ip
        }
        var since: Date?
        if latest.result.isSuccess, now.timeIntervalSince(latest.result.checkedAt) <= interval * 1.5 {
            since = latest.result.checkedAt
            var lastDate = latest.result.checkedAt
            for item in samples.dropLast().reversed() {
                if !item.result.isSuccess || lastDate.timeIntervalSince(item.result.checkedAt) > interval * 1.5 { break }
                if item.result.ipVersion == latest.result.ipVersion {
                    if item.result.ip != latest.result.ip { break }
                    since = item.result.checkedAt
                    lastDate = item.result.checkedAt
                }
            }
        }
        return EgressStabilitySummary(samples: samples.count, failures: samples.count - successful.count, changes: changes,
                                      observedSince: since, latest: latest)
    }
}

public struct EgressStabilitySummary: Sendable {
    public var samples = 0
    public var failures = 0
    public var changes = 0
    public var observedSince: Date?
    public var latest: EgressObservation?
    public init(samples: Int = 0, failures: Int = 0, changes: Int = 0, observedSince: Date? = nil, latest: EgressObservation? = nil) {
        self.samples = samples; self.failures = failures; self.changes = changes; self.observedSince = observedSince; self.latest = latest
    }
}
