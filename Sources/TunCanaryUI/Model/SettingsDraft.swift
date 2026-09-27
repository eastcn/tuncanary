import Foundation
import TunCanaryCore

/// 设置页的编辑草稿。保存前逐项校验，保留尚未保存的输入。
public struct SettingsDraft: Sendable, Equatable {
    public struct SiteDraft: Sendable, Equatable, Identifiable {
        /// 编辑行的身份与内部探测站点 ID 分开，增删站点时列表不会跳动。
        public let editorID: UUID
        public var id: String { editorID.uuidString }
        public var siteID: String
        public var name: String
        /// 分组输入框的原始文本；保存（校验）时才映射为分组，输入过程中不被改写。
        public var groupText: String
        public var url: String
        public var isEnabled: Bool
        public var inLightProbe: Bool

        public init(site: Site) {
            editorID = UUID()
            siteID = site.id
            name = site.name
            groupText = site.group.displayName
            url = site.url.absoluteString
            isEnabled = site.isEnabled
            inLightProbe = site.inLightProbe
        }

        public init() {
            editorID = UUID()
            siteID = "site-1"
            name = ""
            groupText = SiteGroup.mainland.displayName
            url = ""
            isEnabled = true
            inLightProbe = false
        }

        /// 由输入文本映射出的分组（如“japan”“海外”映射为海外组）；赋值时改写输入文本。
        public var group: SiteGroup {
            get { SiteGroup(rawValue: groupText.trimmingCharacters(in: .whitespacesAndNewlines)) }
            set { groupText = newValue.displayName }
        }
    }

    /// 外部检测页的编辑行。
    public struct CheckPageDraft: Sendable, Equatable, Identifiable {
        public let id: UUID
        public var name: String
        public var url: String

        public init(name: String = "", url: String = "") {
            id = UUID()
            self.name = name
            self.url = url
        }
    }

    public struct SiteErrors: Sendable, Equatable {
        public var id: String?
        public var name: String?
        public var url: String?
        public var group: String?
        public var isEmpty: Bool { id == nil && name == nil && url == nil && group == nil }
    }

    public var intranetURL: String
    /// Tailnet 子网目标（IPv4:端口）；留空表示未配置。
    public var tailnetTarget: String
    public var disconnectedDNSRule: DisconnectedDNSRule
    public var expectedDNS: String
    public var connectedDNSRule: ConnectedDNSRule
    public var residualDNSWarning: Bool
    public var proxyClient: ProxyClientKind
    public var manualFakeIPRange: String
    /// 留空表示不检测代理 DNS。
    public var manualDNSPort: String
    public var manualProcessName: String
    public var canaryHost: String
    public var checkPages: [CheckPageDraft]
    /// “检测出口”是否同时访问 claude.ai。
    public var egressIncludesClaude: Bool
    public var notificationsEnabled: Bool
    public var localCheckInterval: String
    public var lightProbeInterval: String
    public var sites: [SiteDraft]

    public init(
        intranetURL: String,
        disconnectedDNSRule: DisconnectedDNSRule? = nil,
        expectedDNS: String,
        connectedDNSRule: ConnectedDNSRule = .vpnProvided,
        residualDNSWarning: Bool = true,
        proxyClient: ProxyClientKind = .clashVergeRev,
        manualProxy: ManualProxyConfig = ManualProxyConfig(),
        canaryHost: String = PulseConstants.canaryHost,
        checkPages: [CheckPage] = [],
        egressTargets: [EgressIPTarget] = AppSettings.defaultEgressTargets,
        notificationsEnabled: Bool,
        localCheckInterval: String = "20",
        lightProbeInterval: String = "120",
        sites: [SiteDraft] = SiteCatalog.defaultSites.map(SiteDraft.init(site:)),
        tailnetTarget: String = ""
    ) {
        self.intranetURL = intranetURL
        self.tailnetTarget = tailnetTarget
        self.disconnectedDNSRule = disconnectedDNSRule ?? AppSettings.inferredRule(DNSList.split(expectedDNS))
        self.expectedDNS = expectedDNS
        self.connectedDNSRule = connectedDNSRule
        self.residualDNSWarning = residualDNSWarning
        self.proxyClient = proxyClient
        self.manualFakeIPRange = manualProxy.fakeIPRange
        self.manualDNSPort = manualProxy.dnsPort.map(String.init) ?? ""
        self.manualProcessName = manualProxy.coreProcessName
        self.canaryHost = canaryHost
        self.checkPages = checkPages.map { CheckPageDraft(name: $0.name, url: $0.url.absoluteString) }
        self.egressIncludesClaude = egressTargets.contains(.claude)
        self.notificationsEnabled = notificationsEnabled
        self.localCheckInterval = localCheckInterval
        self.lightProbeInterval = lightProbeInterval
        self.sites = sites
    }

    /// 由已保存的设置生成草稿。
    public init(settings: AppSettings) {
        self.init(
            intranetURL: settings.intranetURL?.absoluteString ?? "",
            disconnectedDNSRule: settings.disconnectedDNSRule,
            expectedDNS: DNSList.normalize(settings.expectedDNS).joined(separator: ", "),
            connectedDNSRule: settings.connectedDNSRule,
            residualDNSWarning: settings.residualDNSWarning,
            proxyClient: settings.proxyClient,
            manualProxy: settings.manualProxy,
            canaryHost: settings.canaryHost,
            checkPages: settings.checkPages,
            egressTargets: settings.effectiveEgressTargets,
            notificationsEnabled: settings.notificationsEnabled,
            localCheckInterval: Self.intervalText(settings.localCheckInterval),
            lightProbeInterval: Self.intervalText(settings.lightProbeInterval),
            sites: settings.sites.map(SiteDraft.init(site:)),
            tailnetTarget: settings.tailnetTarget?.description ?? "")
    }

    private static func intervalText(_ value: TimeInterval) -> String {
        if value.isFinite, value >= Double(Int.min), value < Double(Int.max), value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    public mutating func addSite() {
        guard sites.count < 20 else { return }
        var site = SiteDraft()
        let existing = Set(sites.map(\.siteID))
        guard let number = (1...20).first(where: { !existing.contains("site-\($0)") }) else { return }
        site.siteID = "site-\(number)"
        sites.append(site)
    }

    /// 尚未加入清单的常用站点模板。
    public var availableTemplates: [Site] {
        let existing = Set(sites.map { $0.siteID.trimmingCharacters(in: .whitespacesAndNewlines) })
        return SiteCatalog.templates.filter { !existing.contains($0.id) }
    }

    /// 加入一个常用站点模板；已存在或已满 20 个时不加。
    public mutating func addTemplate(_ site: Site) {
        guard sites.count < 20, availableTemplates.contains(where: { $0.id == site.id }) else { return }
        sites.append(SiteDraft(site: site))
    }

    public mutating func restoreDefaultSites() {
        sites = SiteCatalog.defaultSites.map(SiteDraft.init(site:))
    }

    /// 校验结果：每个字段的错误信息，以及全部通过时的设置。
    public struct Validation: Sendable, Equatable {
        public var intranetURLError: String?
        public var tailnetTargetError: String?
        public var expectedDNSError: String?
        public var manualFakeIPRangeError: String?
        public var manualDNSPortError: String?
        public var manualProcessNameError: String?
        public var canaryHostError: String?
        /// 按检测页行下标的错误。
        public var checkPageErrors: [Int: String] = [:]
        public var localCheckIntervalError: String?
        public var lightProbeIntervalError: String?
        public var siteCountError: String?
        public var siteErrors: [Int: SiteErrors] = [:]
        /// 全部通过时的设置；有错误时为 nil。
        public var settings: AppSettings?

        public var isValid: Bool { settings != nil }
    }

    public func validate() -> Validation {
        var validation = Validation()
        var url: URL?
        var dns: [String] = []

        switch SettingsValidator.validateIntranetURL(intranetURL) {
        case .success(let value): url = value
        case .failure(let error): validation.intranetURLError = error.message
        }
        var tailnet: TailnetTarget?
        switch SettingsValidator.validateTailnetTarget(tailnetTarget) {
        case .success(let value): tailnet = value
        case .failure(let error): validation.tailnetTargetError = error.message
        }
        // 只有“指定地址”要求填写；其他规则下已填写的地址仍须合法，以便切回时保留。
        if disconnectedDNSRule == .equals || !DNSList.split(expectedDNS).isEmpty {
            switch SettingsValidator.validateExpectedDNS(expectedDNS) {
            case .success(let value): dns = value
            case .failure(let error): validation.expectedDNSError = error.message
            }
        }

        // 手动参数只在选中“手动填写”时校验；其余情况下保留可解析的值，不合法的回落到默认值。
        let portText = manualDNSPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let manual = ManualProxyConfig(
            fakeIPRange: manualFakeIPRange.trimmingCharacters(in: .whitespacesAndNewlines),
            dnsPort: portText.isEmpty ? nil : (Int(portText) ?? -1),
            coreProcessName: manualProcessName.trimmingCharacters(in: .whitespacesAndNewlines))
        let manualErrors = SettingsValidator.validateManualProxy(manual)
        if proxyClient == .manual {
            for error in manualErrors {
                switch error {
                case .manualFakeIPRangeInvalid: validation.manualFakeIPRangeError = error.message
                case .manualDNSPortInvalid: validation.manualDNSPortError = error.message
                case .manualProcessNameInvalid: validation.manualProcessNameError = error.message
                default: break
                }
            }
        }
        let manualProxy = manualErrors.isEmpty ? manual : ManualProxyConfig()
        var pages: [CheckPage] = []
        for (index, draft) in checkPages.enumerated() {
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: draft.url.trimmingCharacters(in: .whitespacesAndNewlines)),
               SettingsValidator.isValidCheckPage(CheckPage(name: name, url: url)) {
                pages.append(CheckPage(name: name, url: url))
            } else {
                validation.checkPageErrors[index] = "名称须为 1–20 个字符，URL 须为含主机名的 http 或 https 地址"
            }
        }
        let host = canaryHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !SettingsValidator.isValidHostName(host) {
            validation.canaryHostError = SettingsValidationError.canaryHostInvalid(host).message
        }

        func interval(_ text: String, range: ClosedRange<Int>, label: String) -> (Int?, String?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int(trimmed), range.contains(value),
                  trimmed.utf8.allSatisfy({ (48...57).contains($0) }) else {
                return (nil, "\(label)须为 \(range.lowerBound)–\(range.upperBound) 秒的整数")
            }
            return (value, nil)
        }
        let (localInterval, localError) = interval(localCheckInterval, range: 5...3600, label: "本机检查间隔")
        let (lightInterval, lightError) = interval(lightProbeInterval, range: 15...86400, label: "后台站点检测间隔")
        validation.localCheckIntervalError = localError
        validation.lightProbeIntervalError = lightError

        if sites.count > 20 { validation.siteCountError = "公开站点最多 20 个" }
        var seenIDs = Set<String>()
        var checkedSites: [Site] = []
        for (index, draft) in sites.enumerated() {
            var errors = SiteErrors()
            let id = draft.siteID.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let urlText = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty || id == SiteCatalog.intranetID || id == SiteCatalog.tailnetID {
                errors.id = "ID 不能为空，且不能使用 intranet 或 tailnet"
            } else if !seenIDs.insert(id).inserted {
                errors.id = "站点 ID 不能重复"
            }
            if !(1...60).contains(name.count) { errors.name = "名称须为 1–60 个字符" }
            let group = draft.group
            if !group.isValidPublicGroup {
                errors.group = "分组须为 1–20 个字符，不能使用“VPN 站点”“Tailnet 子网”或控制字符"
            }
            let parsedURL = URL(string: urlText)
            if let parsedURL,
               let scheme = parsedURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
               let host = parsedURL.host, !host.isEmpty,
               parsedURL.user == nil, parsedURL.password == nil {
                if errors.isEmpty {
                    var site = Site(id: id, name: name, group: group, url: parsedURL,
                                    isKey: draft.inLightProbe, inLightProbe: draft.inLightProbe)
                    site.isEnabled = draft.isEnabled
                    checkedSites.append(site)
                }
            } else {
                errors.url = "URL 须为含主机名的 http 或 https 地址，不能包含账号或密码"
            }
            if !errors.isEmpty { validation.siteErrors[index] = errors }
        }

        if validation.intranetURLError == nil && validation.tailnetTargetError == nil &&
           validation.expectedDNSError == nil &&
           (proxyClient != .manual || manualErrors.isEmpty) && validation.canaryHostError == nil &&
           validation.checkPageErrors.isEmpty && checkPages.count <= AppSettings.maxCheckPages &&
           localError == nil && lightError == nil &&
           validation.siteCountError == nil && validation.siteErrors.isEmpty,
           let localInterval, let lightInterval {
            validation.settings = AppSettings(
                intranetURL: url,
                disconnectedDNSRule: disconnectedDNSRule,
                expectedDNS: dns,
                connectedDNSRule: connectedDNSRule,
                residualDNSWarning: residualDNSWarning,
                proxyClient: proxyClient,
                manualProxy: manualProxy,
                canaryHost: host,
                checkPages: pages,
                egressTargets: egressIncludesClaude ? [.claude, .cloudflare] : [.cloudflare],
                notificationsEnabled: notificationsEnabled,
                localCheckInterval: TimeInterval(localInterval),
                lightProbeInterval: TimeInterval(lightInterval),
                sites: checkedSites,
                tailnetTarget: tailnet)
        }
        return validation
    }

    /// 草稿校验通过，且与已保存的设置不同。
    public func hasChanges(comparedTo saved: AppSettings) -> Bool {
        guard let settings = validate().settings else { return true }
        return settings != Self.normalized(saved)
    }

    /// 与草稿同样规范化后的设置，用于比较。
    static func normalized(_ settings: AppSettings) -> AppSettings {
        SettingsDraft(settings: settings).validate().settings ?? settings
    }
}
