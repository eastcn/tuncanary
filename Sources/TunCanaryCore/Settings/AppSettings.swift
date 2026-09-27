import Foundation

/// VPN 断开、TUN 运行时，主网络保存的 DNS 应满足的规则。
public enum DisconnectedDNSRule: String, Sendable, Equatable, Codable, CaseIterable {
    /// 不检查保存值，只看系统解析是否经过代理。
    case notSet
    /// 等于 `expectedDNS`（忽略顺序）。
    case equals
    /// 应为空（由 DHCP 下发）。
    case empty

    public var displayName: String {
        switch self {
        case .notSet: return "不检查"
        case .equals: return "指定地址"
        case .empty: return "为空"
        }
    }
}

/// VPN 连接时，主网络保存的 DNS 应满足的规则。
public enum ConnectedDNSRule: String, Sendable, Equatable, Codable, CaseIterable {
    /// 不检查。
    case notSet
    /// 是 VPN 适配器报告的 DNS 的子集；适配器不报告 DNS 时不检查。
    case vpnProvided
    /// 由代理接管：TUN 运行时与断开期同样检查（保存的 DNS 符合断开期规则，系统解析返回 fake-ip）。
    /// VPN 域名由代理按域名策略解析。
    case proxyTakeover

    public var displayName: String {
        switch self {
        case .notSet: return "不检查"
        case .vpnProvided: return "VPN 下发的 DNS"
        case .proxyTakeover: return "由代理接管（与断开时相同）"
        }
    }
}

/// 代理客户端。
public enum ProxyClientKind: String, Sendable, Equatable, Codable, CaseIterable {
    /// 读取 Clash Verge Rev 的配置文件。
    case clashVergeRev
    /// 不读取配置，使用用户填写的 fake-ip 网段、DNS 端口和核心进程名。
    case manual

    public var displayName: String {
        switch self {
        case .clashVergeRev: return "Clash Verge Rev"
        case .manual: return "手动填写"
        }
    }
}

/// 手动模式的代理参数。
public struct ManualProxyConfig: Sendable, Equatable, Codable {
    /// fake-ip 网段，例如 `198.18.0.0/15`。
    public var fakeIPRange: String
    /// 代理 DNS 在本机监听的端口；为 nil 时不检测代理 DNS。
    public var dnsPort: Int?
    /// 核心进程的可执行文件名，例如 `mihomo`；为空时不检查进程。
    public var coreProcessName: String

    public static let defaultFakeIPRange = "198.18.0.0/15"

    public init(fakeIPRange: String = ManualProxyConfig.defaultFakeIPRange, dnsPort: Int? = nil,
                coreProcessName: String = "") {
        self.fakeIPRange = fakeIPRange
        self.dnsPort = dnsPort
        self.coreProcessName = coreProcessName
    }

    public var fakeIPNetwork: IPv4CIDR? {
        IPv4CIDR(fakeIPRange.trimmingCharacters(in: .whitespaces))
    }
}

/// 弹窗中的外部检测页（在浏览器中打开）。
public struct CheckPage: Sendable, Equatable, Codable {
    public var name: String
    public var url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// 采集时使用的代理来源：客户端种类和手动参数。
public struct ProxySource: Sendable, Equatable {
    public var client: ProxyClientKind
    public var manual: ManualProxyConfig

    public init(client: ProxyClientKind = .clashVergeRev, manual: ManualProxyConfig = ManualProxyConfig(),
                canaryHost: String = PulseConstants.canaryHost) {
        self.client = client
        self.manual = manual
        self.canaryHost = canaryHost
    }

    /// 系统解析 canary 查询的域名。须不在代理的 fake-ip 过滤名单中。
    public var canaryHost: String = PulseConstants.canaryHost

    /// 状态卡与提示中的名称。
    public var tunLabel: String { client == .manual ? "代理 TUN" : "Clash TUN" }
    public var dnsLabel: String { client == .manual ? "代理 DNS" : "Mihomo DNS" }
    /// 恢复步骤中“在哪里重开 TUN”。
    public var clientLabel: String { client == .manual ? "代理客户端" : "Clash Verge" }
}

/// 应用设置。应用和命令行共用，保存在 `UserDefaults(suiteName: AppIdentity.bundleID)`。
/// 登录时启动不在此保存，而是读取系统实际状态（见 `LoginItemControlling`）。
public struct AppSettings: Sendable, Equatable, Codable {
    public static let defaultEgressTargets: [EgressIPTarget] = [.cloudflare]
    public static let maxCheckPages = 3
    public static let defaultLocalCheckInterval: TimeInterval = 20
    public static let defaultLightProbeInterval: TimeInterval = 120
    public static let `default` = AppSettings()

    /// VPN 站点 URL，只在 VPN 已连接时探测；未配置为 nil。
    public var intranetURL: URL?
    /// Tailnet 子网目标（IPv4:端口），只在经 Tailscale 路由时做 TCP 探测；未配置为 nil。
    public var tailnetTarget: TailnetTarget?
    /// VPN 断开、TUN 运行时的 DNS 规则。
    public var disconnectedDNSRule: DisconnectedDNSRule
    /// `disconnectedDNSRule` 为 `.equals` 时的预期 DNS（一个或多个 IPv4）。
    public var expectedDNS: [String]
    /// VPN 连接时的 DNS 规则。
    public var connectedDNSRule: ConnectedDNSRule
    /// TUN 关闭时，保存的 DNS 仍含预期 DNS 则提示残留。只在 `disconnectedDNSRule` 为 `.equals` 时生效。
    public var residualDNSWarning: Bool
    /// 代理客户端，默认 Clash Verge Rev。
    public var proxyClient: ProxyClientKind
    /// 手动模式的参数；`proxyClient` 为 `.manual` 时生效。
    public var manualProxy: ManualProxyConfig
    /// 系统解析 canary 查询的域名，默认 `www.google.com`。
    public var canaryHost: String
    /// 外部检测页，最多 3 个，默认不提供。
    public var checkPages: [CheckPage]
    /// “检测出口”访问的目标，默认只有 Cloudflare。
    public var egressTargets: [EgressIPTarget]
    /// 通知开关，默认开启。
    public var notificationsEnabled: Bool
    /// 本机检查与后台站点轻测周期（秒）。
    public var localCheckInterval: TimeInterval
    public var lightProbeInterval: TimeInterval
    /// 公开站点清单；空数组表示明确不探测公开站点。
    public var sites: [Site]

    /// - Parameter disconnectedDNSRule: 省略时按 `expectedDNS` 推断：非空为 `.equals`，否则为 `.notSet`。
    public init(
        intranetURL: URL? = nil,
        disconnectedDNSRule: DisconnectedDNSRule? = nil,
        expectedDNS: [String] = [],
        connectedDNSRule: ConnectedDNSRule = .vpnProvided,
        residualDNSWarning: Bool = true,
        proxyClient: ProxyClientKind = .clashVergeRev,
        manualProxy: ManualProxyConfig = ManualProxyConfig(),
        canaryHost: String = PulseConstants.canaryHost,
        checkPages: [CheckPage] = [],
        egressTargets: [EgressIPTarget] = AppSettings.defaultEgressTargets,
        notificationsEnabled: Bool = true,
        localCheckInterval: TimeInterval = AppSettings.defaultLocalCheckInterval,
        lightProbeInterval: TimeInterval = AppSettings.defaultLightProbeInterval,
        sites: [Site] = SiteCatalog.defaultSites,
        tailnetTarget: TailnetTarget? = nil
    ) {
        self.intranetURL = intranetURL
        self.tailnetTarget = tailnetTarget
        self.disconnectedDNSRule = disconnectedDNSRule ?? Self.inferredRule(expectedDNS)
        self.expectedDNS = expectedDNS
        self.connectedDNSRule = connectedDNSRule
        self.residualDNSWarning = residualDNSWarning
        self.proxyClient = proxyClient
        self.manualProxy = manualProxy
        self.canaryHost = canaryHost
        self.checkPages = checkPages
        self.egressTargets = egressTargets
        self.notificationsEnabled = notificationsEnabled
        self.localCheckInterval = localCheckInterval
        self.lightProbeInterval = lightProbeInterval
        self.sites = sites
    }

    /// 旧版设置只有预期 DNS：有值时视为 `.equals`。
    public static func inferredRule(_ expectedDNS: [String]) -> DisconnectedDNSRule {
        DNSList.normalize(expectedDNS).isEmpty ? .notSet : .equals
    }

    private enum CodingKeys: String, CodingKey {
        case intranetURL, disconnectedDNSRule, expectedDNS, connectedDNSRule, residualDNSWarning
        case proxyClient, manualProxy, canaryHost, checkPages, egressTargets
        case notificationsEnabled, localCheckInterval, lightProbeInterval, sites, tailnetTarget
    }

    /// 旧版 JSON 没有规则、周期和站点字段；缺失时沿用旧默认值。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        intranetURL = try values.decodeIfPresent(URL.self, forKey: .intranetURL)
        expectedDNS = try values.decodeIfPresent([String].self, forKey: .expectedDNS) ?? []
        disconnectedDNSRule = try values.decodeIfPresent(DisconnectedDNSRule.self, forKey: .disconnectedDNSRule)
            ?? Self.inferredRule(expectedDNS)
        connectedDNSRule = try values.decodeIfPresent(ConnectedDNSRule.self, forKey: .connectedDNSRule) ?? .vpnProvided
        residualDNSWarning = try values.decodeIfPresent(Bool.self, forKey: .residualDNSWarning) ?? true
        proxyClient = try values.decodeIfPresent(ProxyClientKind.self, forKey: .proxyClient) ?? .clashVergeRev
        manualProxy = try values.decodeIfPresent(ManualProxyConfig.self, forKey: .manualProxy) ?? ManualProxyConfig()
        canaryHost = try values.decodeIfPresent(String.self, forKey: .canaryHost) ?? PulseConstants.canaryHost
        checkPages = try values.decodeIfPresent([CheckPage].self, forKey: .checkPages) ?? []
        egressTargets = try values.decodeIfPresent([EgressIPTarget].self, forKey: .egressTargets) ?? Self.defaultEgressTargets
        notificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        localCheckInterval = try values.decodeIfPresent(TimeInterval.self, forKey: .localCheckInterval)
            ?? Self.defaultLocalCheckInterval
        lightProbeInterval = try values.decodeIfPresent(TimeInterval.self, forKey: .lightProbeInterval)
            ?? Self.defaultLightProbeInterval
        sites = try values.decodeIfPresent([Site].self, forKey: .sites) ?? SiteCatalog.defaultSites
        tailnetTarget = try? values.decodeIfPresent(TailnetTarget.self, forKey: .tailnetTarget)
    }

    /// 实际检测的出口目标：按固定顺序去重，为空时回落到默认值。
    public var effectiveEgressTargets: [EgressIPTarget] {
        let chosen = EgressIPTarget.allCases.filter(egressTargets.contains)
        return chosen.isEmpty ? Self.defaultEgressTargets : chosen
    }

    /// 采集与判定使用的代理来源。
    public var proxySource: ProxySource {
        ProxySource(client: proxyClient, manual: manualProxy, canaryHost: canaryHost)
    }

    /// 规范化后的预期 DNS。
    public var effectiveExpectedDNS: [String] {
        DNSList.normalize(expectedDNS)
    }

    public var effectiveLocalCheckInterval: TimeInterval {
        SettingsValidator.validInterval(localCheckInterval, range: 5...3600)
            ? localCheckInterval : Self.defaultLocalCheckInterval
    }

    public var effectiveLightProbeInterval: TimeInterval {
        SettingsValidator.validInterval(lightProbeInterval, range: 15...86400)
            ? lightProbeInterval : Self.defaultLightProbeInterval
    }

    public var enabledSites: [Site] { sites.filter(\.isEnabled) }

    /// 是否已配置 VPN 站点 URL。
    public var isIntranetConfigured: Bool {
        intranetURL != nil
    }
}

/// 设置校验错误。`message` 为界面直接展示的中文。
public enum SettingsValidationError: Error, Equatable, Sendable {
    case intranetURLInvalid
    case intranetURLScheme
    case intranetURLMissingHost
    case tailnetTargetInvalid
    case expectedDNSEmpty
    case expectedDNSInvalid(String)
    case localCheckIntervalInvalid
    case lightProbeIntervalInvalid
    case tooManySites
    case siteIDInvalid
    case siteIDDuplicate(String)
    case siteNameInvalid(String)
    case siteGroupInvalid(String)
    case siteURLInvalid(String)
    case siteURLCredentials(String)
    case manualFakeIPRangeInvalid(String)
    case manualDNSPortInvalid
    case manualProcessNameInvalid
    case canaryHostInvalid(String)
    case tooManyCheckPages
    case checkPageInvalid(Int)

    public var message: String {
        switch self {
        case .intranetURLInvalid:
            return "VPN 站点 URL 格式不正确"
        case .intranetURLScheme:
            return "VPN 站点 URL 必须是 http 或 https"
        case .intranetURLMissingHost:
            return "VPN 站点 URL 缺少主机名"
        case .tailnetTargetInvalid:
            return "Tailnet 子网目标须为“IPv4 地址:端口”，例如 192.168.1.10:443"
        case .expectedDNSEmpty:
            return "预期 DNS 至少填写一个 IPv4 地址"
        case .expectedDNSInvalid(let value):
            return "“\(value)”不是有效的 IPv4 地址"
        case .localCheckIntervalInvalid:
            return "本机检查间隔须为 5 至 3600 的整数秒"
        case .lightProbeIntervalInvalid:
            return "后台轻测间隔须为 15 至 86400 的整数秒"
        case .tooManySites:
            return "公开站点最多只能配置 20 个"
        case .siteIDInvalid:
            return "站点 ID 不能为空，且不能使用 VPN 站点或 Tailnet 子网的保留 ID"
        case .siteIDDuplicate(let id):
            return "站点 ID“\(id)”重复"
        case .siteNameInvalid(let id):
            return "站点“\(id)”的名称须为 1 至 60 个字符"
        case .siteGroupInvalid(let id):
            return "站点“\(id)”的公开分组须为 1 至 20 个字符，不能使用“VPN 站点”“Tailnet 子网”或控制字符"
        case .siteURLInvalid(let id):
            return "站点“\(id)”的 URL 须为包含主机名的 http 或 https 地址"
        case .siteURLCredentials(let id):
            return "站点“\(id)”的 URL 不能包含用户名或密码"
        case .manualFakeIPRangeInvalid(let value):
            return "“\(value)”不是有效的 CIDR 网段（例如 198.18.0.0/15）"
        case .manualDNSPortInvalid:
            return "代理 DNS 端口须为 1–65535 的整数，留空表示不检测"
        case .manualProcessNameInvalid:
            return "核心进程名须为 1–64 个字符，不能含 /"
        case .canaryHostInvalid(let value):
            return "“\(value)”不是有效的域名（例如 www.google.com）"
        case .tooManyCheckPages:
            return "检测页最多 \(AppSettings.maxCheckPages) 个"
        case .checkPageInvalid(let index):
            return "第 \(index + 1) 个检测页的名称须为 1–20 个字符，URL 须为含主机名的 http 或 https 地址，且不含账号或密码"
        }
    }
}

/// 设置校验。
public enum SettingsValidator {
    public static func validInterval(_ value: TimeInterval, range: ClosedRange<Int>) -> Bool {
        value.isFinite && value.rounded(.towardZero) == value
            && value >= Double(range.lowerBound) && value <= Double(range.upperBound)
    }

    public static func validateSites(_ sites: [Site]) -> [SettingsValidationError] {
        var errors: [SettingsValidationError] = []
        if sites.count > 20 { errors.append(.tooManySites) }
        var ids = Set<String>()
        for site in sites {
            let id = site.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty || site.id == SiteCatalog.intranetID || site.id == SiteCatalog.tailnetID {
                errors.append(.siteIDInvalid)
            }
            if !ids.insert(site.id).inserted { errors.append(.siteIDDuplicate(site.id)) }
            let name = site.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.count > 60 { errors.append(.siteNameInvalid(site.id)) }
            if !site.group.isValidPublicGroup {
                errors.append(.siteGroupInvalid(site.id))
            }
            let scheme = site.url.scheme?.lowercased()
            if (scheme != "http" && scheme != "https") || (site.url.host?.isEmpty != false) {
                errors.append(.siteURLInvalid(site.id))
            }
            if site.url.user != nil || site.url.password != nil { errors.append(.siteURLCredentials(site.id)) }
        }
        return errors
    }

    /// VPN 站点 URL：空串表示未配置；否则必须是 http 或 https 且含主机名。
    public static func validateIntranetURL(_ text: String) -> Result<URL?, SettingsValidationError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(nil) }
        guard let url = URL(string: trimmed) else { return .failure(.intranetURLInvalid) }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failure(.intranetURLScheme)
        }
        guard let host = url.host, !host.isEmpty else { return .failure(.intranetURLMissingHost) }
        return .success(url)
    }

    /// Tailnet 子网目标：空串表示未配置；否则须为 `IPv4:端口`。
    public static func validateTailnetTarget(_ text: String) -> Result<TailnetTarget?, SettingsValidationError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(nil) }
        guard let target = TailnetTarget(trimmed) else { return .failure(.tailnetTargetInvalid) }
        return .success(target)
    }

    /// 手动模式参数：网段必须合法；端口可空；进程名可空，非空时不能含 `/`。
    public static func validateManualProxy(_ manual: ManualProxyConfig) -> [SettingsValidationError] {
        var errors: [SettingsValidationError] = []
        if manual.fakeIPNetwork == nil { errors.append(.manualFakeIPRangeInvalid(manual.fakeIPRange)) }
        if let port = manual.dnsPort, !(1...65535).contains(port) { errors.append(.manualDNSPortInvalid) }
        let name = manual.coreProcessName.trimmingCharacters(in: .whitespaces)
        if name.count > 64 || name.contains("/") { errors.append(.manualProcessNameInvalid) }
        return errors
    }

    public static func validateCheckPages(_ pages: [CheckPage]) -> [SettingsValidationError] {
        var errors: [SettingsValidationError] = []
        if pages.count > AppSettings.maxCheckPages { errors.append(.tooManyCheckPages) }
        for (index, page) in pages.enumerated() where !isValidCheckPage(page) {
            errors.append(.checkPageInvalid(index))
        }
        return errors
    }

    public static func isValidCheckPage(_ page: CheckPage) -> Bool {
        let name = page.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = page.url.scheme?.lowercased()
        return (1...20).contains(name.count) && (scheme == "http" || scheme == "https")
            && page.url.host?.isEmpty == false && page.url.user == nil && page.url.password == nil
    }

    /// 域名：至少两段，每段 1–63 个字母、数字或 `-`，不以 `-` 开头或结尾，总长不超过 253。不接受 IP 地址。
    public static func isValidHostName(_ text: String) -> Bool {
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard text.count <= 253, labels.count >= 2, IPv4(text) == nil else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return labels.allSatisfy { label in
            (1...63).contains(label.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    /// 预期 DNS：逗号、顿号或空白分隔的一个或多个 IPv4。
    public static func validateExpectedDNS(_ text: String) -> Result<[String], SettingsValidationError> {
        validateExpectedDNS(DNSList.split(text))
    }

    public static func validateExpectedDNS(_ list: [String]) -> Result<[String], SettingsValidationError> {
        let normalized = DNSList.normalize(list)
        guard !normalized.isEmpty else { return .failure(.expectedDNSEmpty) }
        for item in normalized where IPv4(item) == nil {
            return .failure(.expectedDNSInvalid(item))
        }
        return .success(normalized)
    }

    /// 校验整份设置，返回全部错误；空数组表示通过。
    public static func validate(_ settings: AppSettings) -> [SettingsValidationError] {
        var errors: [SettingsValidationError] = []
        if let url = settings.intranetURL, case .failure(let error) = validateIntranetURL(url.absoluteString) {
            errors.append(error)
        }
        if settings.disconnectedDNSRule == .equals || !DNSList.normalize(settings.expectedDNS).isEmpty,
           case .failure(let error) = validateExpectedDNS(settings.expectedDNS) {
            errors.append(error)
        }
        if !validInterval(settings.localCheckInterval, range: 5...3600) {
            errors.append(.localCheckIntervalInvalid)
        }
        if !validInterval(settings.lightProbeInterval, range: 15...86400) {
            errors.append(.lightProbeIntervalInvalid)
        }
        if settings.proxyClient == .manual {
            errors += validateManualProxy(settings.manualProxy)
        }
        if !isValidHostName(settings.canaryHost) {
            errors.append(.canaryHostInvalid(settings.canaryHost))
        }
        errors += validateCheckPages(settings.checkPages)
        errors += validateSites(settings.sites)
        return errors
    }
}
