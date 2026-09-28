import Foundation

/// 设置读写。Core 中少数做 I/O 的类型之一（另见 `VPNAdapterStore`、`FaultEventStore`）。
///
/// 应用与命令行都运行在 bundle id 为 `AppIdentity.bundleID` 的包内，此时系统不允许把自身
/// bundle id 当作 suite 名，所以直接使用 `.standard`（二者是同一个域）；在包外（如 `swift run`）
/// 才使用 `UserDefaults(suiteName:)`。
public final class SettingsStore: @unchecked Sendable {
    public enum Key {
        public static let intranetURL = "intranetURL"
        public static let tailnetTarget = "tailnet.target"
        public static let proxyDiagnostics = "proxy.diagnostics"
        public static let expectedDNS = "expectedDNS"
        /// 旧版没有以下三个键：缺失时按旧行为迁移（有预期 DNS 即为 `equals`）。
        public static let disconnectedDNSRule = "dnsRule.vpnDisconnected"
        public static let connectedDNSRule = "dnsRule.vpnConnected"
        public static let residualDNSWarning = "dnsRule.residualWhenTUNOff"
        public static let proxyClient = "proxy.client"
        /// 手动模式参数（JSON）。
        public static let manualProxy = "proxy.manual"
        public static let canaryHost = "probe.canaryHost"
        /// 外部检测页（JSON）。
        public static let checkPages = "checkPages"
        public static let egressMonitoring = "egress.monitoring"
        public static let egressTargets = "egress.targets"
        public static let notificationsEnabled = "notificationsEnabled"
        public static let localCheckInterval = "localCheckInterval"
        public static let lightProbeInterval = "lightProbeInterval"
        public static let sites = "sites"
        /// 站点数据含不合法项或无法解码时，读取前备份的原始数据。
        public static let sitesInvalidBackup = "sites.invalidBackup"
        public static let all = [intranetURL, tailnetTarget, proxyDiagnostics, expectedDNS, disconnectedDNSRule, connectedDNSRule,
                                 residualDNSWarning, proxyClient, manualProxy, canaryHost, checkPages,
                                 egressTargets, egressMonitoring, notificationsEnabled,
                                 localCheckInterval, lightProbeInterval, sites, sitesInvalidBackup]
    }

    public let defaults: UserDefaults

    public init(suiteName: String = AppIdentity.bundleID) {
        if Bundle.main.bundleIdentifier == suiteName {
            defaults = .standard
        } else {
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
        }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// 读取设置。缺失或非法的项回落到默认值；站点列表逐个过滤，见 `loadSites(from:)`。
    public func load() -> AppSettings {
        var settings = AppSettings()
        if let text = defaults.string(forKey: Key.intranetURL),
           case .success(let url) = SettingsValidator.validateIntranetURL(text) {
            settings.intranetURL = url
        }
        if let text = defaults.string(forKey: Key.tailnetTarget),
           case .success(let target) = SettingsValidator.validateTailnetTarget(text) {
            settings.tailnetTarget = target
        }
        if defaults.object(forKey: Key.proxyDiagnostics) != nil {
            settings.proxyDiagnosticsEnabled = defaults.bool(forKey: Key.proxyDiagnostics)
        }
        if let list = defaults.stringArray(forKey: Key.expectedDNS),
           case .success(let dns) = SettingsValidator.validateExpectedDNS(list) {
            settings.expectedDNS = dns
        }
        if let text = defaults.string(forKey: Key.disconnectedDNSRule), let rule = DisconnectedDNSRule(rawValue: text) {
            settings.disconnectedDNSRule = rule
        } else {
            settings.disconnectedDNSRule = AppSettings.inferredRule(settings.expectedDNS)
        }
        if settings.disconnectedDNSRule == .equals && settings.effectiveExpectedDNS.isEmpty {
            settings.disconnectedDNSRule = .notSet
        }
        if let text = defaults.string(forKey: Key.connectedDNSRule), let rule = ConnectedDNSRule(rawValue: text) {
            settings.connectedDNSRule = rule
        }
        if defaults.object(forKey: Key.residualDNSWarning) != nil {
            settings.residualDNSWarning = defaults.bool(forKey: Key.residualDNSWarning)
        }
        var manualLoaded = false
        if let data = defaults.data(forKey: Key.manualProxy),
           let manual = try? JSONDecoder().decode(ManualProxyConfig.self, from: data),
           SettingsValidator.validateManualProxy(manual).isEmpty {
            settings.manualProxy = manual
            manualLoaded = true
        }
        if let host = defaults.string(forKey: Key.canaryHost), SettingsValidator.isValidHostName(host) {
            settings.canaryHost = host
        }
        if let data = defaults.data(forKey: Key.checkPages),
           let pages = try? JSONDecoder().decode([CheckPage].self, from: data) {
            settings.checkPages = Array(pages.filter(SettingsValidator.isValidCheckPage).prefix(AppSettings.maxCheckPages))
        }
        if let data = defaults.data(forKey: Key.egressMonitoring),
           let config = try? JSONDecoder().decode(EgressMonitoringSettings.self, from: data), config.isValid {
            settings.egressMonitoring = config
        }
        if let list = defaults.stringArray(forKey: Key.egressTargets) {
            let targets = list.compactMap(EgressIPTarget.init(rawValue:))
            if !targets.isEmpty { settings.egressTargets = targets }
        }
        if let text = defaults.string(forKey: Key.proxyClient), let client = ProxyClientKind(rawValue: text) {
            // 手动参数缺失或不合法时不能进入手动模式。
            settings.proxyClient = client == .manual && !manualLoaded ? .clashVergeRev : client
        }
        if defaults.object(forKey: Key.notificationsEnabled) != nil {
            settings.notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        }
        if let number = defaults.object(forKey: Key.localCheckInterval) as? NSNumber,
           SettingsValidator.validInterval(number.doubleValue, range: 5...3600) {
            settings.localCheckInterval = number.doubleValue
        }
        if let number = defaults.object(forKey: Key.lightProbeInterval) as? NSNumber,
           SettingsValidator.validInterval(number.doubleValue, range: 15...86400) {
            settings.lightProbeInterval = number.doubleValue
        }
        if let data = defaults.data(forKey: Key.sites) {
            settings.sites = loadSites(from: data) ?? settings.sites
        }
        return settings
    }

    /// 逐个过滤不合法的站点，保留合法项；有站点被丢弃或整份数据无法解码时，先备份原始数据。
    /// 整份无法解码，或原本非空但没有一个合法站点时返回 nil，由调用方采用默认站点。
    private func loadSites(from data: Data) -> [Site]? {
        guard let decoded = try? JSONDecoder().decode([LossySite].self, from: data) else {
            defaults.set(data, forKey: Key.sitesInvalidBackup)
            return nil
        }
        var sites: [Site] = []
        var ids = Set<String>()
        for case let site? in decoded.map(\.site) where sites.count < 20 {
            guard SettingsValidator.validateSites([site]).isEmpty, !ids.contains(site.id) else { continue }
            ids.insert(site.id)
            sites.append(site)
        }
        if sites.count != decoded.count { defaults.set(data, forKey: Key.sitesInvalidBackup) }
        if sites.isEmpty && !decoded.isEmpty { return nil }
        return sites
    }

    /// 保存设置。可选项为空时删除对应键。
    public func save(_ settings: AppSettings) {
        if let url = settings.intranetURL {
            defaults.set(url.absoluteString, forKey: Key.intranetURL)
        } else {
            defaults.removeObject(forKey: Key.intranetURL)
        }
        if let target = settings.tailnetTarget {
            defaults.set(target.description, forKey: Key.tailnetTarget)
        } else {
            defaults.removeObject(forKey: Key.tailnetTarget)
        }
        defaults.set(settings.proxyDiagnosticsEnabled, forKey: Key.proxyDiagnostics)
        defaults.set(DNSList.normalize(settings.expectedDNS), forKey: Key.expectedDNS)
        defaults.set(settings.disconnectedDNSRule.rawValue, forKey: Key.disconnectedDNSRule)
        defaults.set(settings.connectedDNSRule.rawValue, forKey: Key.connectedDNSRule)
        defaults.set(settings.residualDNSWarning, forKey: Key.residualDNSWarning)
        defaults.set(settings.proxyClient.rawValue, forKey: Key.proxyClient)
        defaults.set(settings.canaryHost, forKey: Key.canaryHost)
        if let data = try? JSONEncoder().encode(settings.checkPages) {
            defaults.set(data, forKey: Key.checkPages)
        }
        if let data = try? JSONEncoder().encode(settings.egressMonitoring) { defaults.set(data, forKey: Key.egressMonitoring) }
        defaults.set(settings.effectiveEgressTargets.map(\.rawValue), forKey: Key.egressTargets)
        if let data = try? JSONEncoder().encode(settings.manualProxy) {
            defaults.set(data, forKey: Key.manualProxy)
        }
        defaults.set(settings.notificationsEnabled, forKey: Key.notificationsEnabled)
        defaults.set(settings.localCheckInterval, forKey: Key.localCheckInterval)
        defaults.set(settings.lightProbeInterval, forKey: Key.lightProbeInterval)
        if let data = try? JSONEncoder().encode(settings.sites) {
            defaults.set(data, forKey: Key.sites)
        }
    }

    /// 删除全部设置键（卸载时可选清除）。
    public func removeAll() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
    }
}

/// 单个站点解码失败时记为 nil，不影响其余站点。
private struct LossySite: Decodable {
    let site: Site?

    init(from decoder: Decoder) throws {
        site = try? Site(from: decoder)
    }
}
