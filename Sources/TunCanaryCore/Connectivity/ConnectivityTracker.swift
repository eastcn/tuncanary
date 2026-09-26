import Foundation

/// 连通性故障。
public struct ConnectivityFault: Sendable, Hashable {
    public var key: FaultKey
    public var severity: Severity
    public var message: String
    /// 相关站点 ID。
    public var siteIDs: [String]

    public init(key: FaultKey, severity: Severity, message: String, siteIDs: [String]) {
        self.key = key
        self.severity = severity
        self.message = message
        self.siteIDs = siteIDs
    }

    public var fault: Fault {
        Fault(key: key, severity: severity, message: message)
    }
}

/// 失败的计数语境，决定文案。
public enum FailureContext: Sendable {
    /// 应用内：连续两轮失败。
    case consecutiveRounds
    /// `--check` 单次运行：两次请求都失败。
    case singleCheck
    /// `--check --full`：三次请求的站点汇总结果为失败。
    case fullCheck

    var phrase: String {
        switch self {
        case .consecutiveRounds: return "连续两轮访问失败"
        case .singleCheck: return "两次请求均失败"
        case .fullCheck: return "完整检测失败"
        }
    }
}

/// 维护关键站点的连续失败计数，并按计划告警规则产出故障。
public struct ConnectivityTracker: Sendable, Equatable {
    public let threshold: Int
    /// siteID → 连续失败轮数。
    public private(set) var consecutiveFailures: [String: Int]

    public init(threshold: Int = PulseConstants.consecutiveFailureThreshold) {
        self.threshold = threshold
        consecutiveFailures = [:]
    }

    /// 记录一轮结果（后台轻测，或手动完整检测中关键站点的汇总结果）。
    /// 只统计关键站点；内网站点仅在 `intranetEligible`（VPN 已连接且已配置）时参与，否则计数清零。
    /// 本轮未出现的关键站点保持原计数。
    public mutating func recordRound(_ results: [SiteResult], intranetEligible: Bool) {
        for result in results where result.site.isKey && result.site.inLightProbe && result.site.isEnabled {
            if result.site.group == .intranet && !intranetEligible { continue }
            if result.isFailure {
                consecutiveFailures[result.site.id, default: 0] += 1
            } else {
                consecutiveFailures[result.site.id] = 0
            }
        }
        if !intranetEligible {
            consecutiveFailures[SiteCatalog.intranetID] = nil
        }
    }

    /// 清零全部计数（宽限期结束、网络变化后）。
    public mutating func reset() {
        consecutiveFailures = [:]
    }

    /// 只清零指定站点的计数（探测目标改变或站点删除后），其余站点保留。
    public mutating func reset(siteIDs: Set<String>) {
        for id in siteIDs { consecutiveFailures[id] = nil }
    }

    public func failureCount(for siteID: String) -> Int {
        consecutiveFailures[siteID] ?? 0
    }

    /// 达到门槛的站点。
    public var failingSiteIDs: Set<String> {
        Set(consecutiveFailures.filter { $0.value >= threshold }.keys)
    }

    /// 当前故障。
    public var faults: [ConnectivityFault] {
        faults(sites: SiteCatalog.defaultSites)
    }

    /// 按当前配置计算故障；已删除或禁用站点的旧计数不再参与判定。
    public func faults(sites: [Site]) -> [ConnectivityFault] {
        Self.faults(failingSiteIDs: failingSiteIDs, context: .consecutiveRounds, sites: sites)
    }

    /// 当前公开组中的关键后台站点单站失败为黄；某组全部失败为红。
    /// 默认大陆组只有百度，保留其原有的单条红色告警与文案。
    public static func faults(failingSiteIDs failing: Set<String>, context: FailureContext,
                              sites: [Site] = SiteCatalog.defaultSites) -> [ConnectivityFault] {
        var faults: [ConnectivityFault] = []
        let phrase = context.phrase
        for group in SiteGroup.publicGroups(for: sites) {
            let keys = sites.filter { $0.group == group && $0.id != SiteCatalog.intranetID
                && $0.isEnabled && $0.isKey && $0.inLightProbe }
            guard !keys.isEmpty else { continue }
            let failed = keys.filter { failing.contains($0.id) }
            guard !failed.isEmpty else { continue }
            let allFailed = failed.count == keys.count
            let legacyBaidu = group == .mainland && keys == [SiteCatalog.baidu]
            if !legacyBaidu {
                for site in failed {
                    faults.append(ConnectivityFault(key: .site(site.id), severity: .warning,
                                                    message: "\(site.name) \(phrase)", siteIDs: [site.id]))
                }
            }
            if allFailed {
                let message: String
                if legacyBaidu {
                    message = "百度\(phrase)，国内出口故障"
                } else {
                    let names = failed.map(\.name).joined(separator: " 与 ")
                    let suffix: String
                    if group == .mainland {
                        suffix = "国内出口故障"
                    } else {
                        suffix = "\(group.displayName)访问故障"
                    }
                    message = "\(names) 均\(phrase)，\(suffix)"
                }
                faults.append(ConnectivityFault(key: .group(group), severity: .critical,
                                                message: message, siteIDs: keys.map(\.id)))
            }
        }
        if failing.contains(SiteCatalog.intranetID) {
            faults.append(ConnectivityFault(
                key: .site(SiteCatalog.intranetID), severity: .warning,
                message: "内网站点\(phrase)", siteIDs: [SiteCatalog.intranetID]))
        }
        return faults
    }
}
