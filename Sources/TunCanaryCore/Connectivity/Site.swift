import Foundation

/// 公开站点分组。自定义组以组名为标识；`intranet` 专供 VPN 门槛下的 VPN 站点，`tailnet` 专供经 Tailscale 探测的 Tailnet 子网。
public struct SiteGroup: RawRepresentable, Hashable, Sendable, Codable, CaseIterable {
    public let rawValue: String

    public init(rawValue: String) {
        // 旧版日本组并入海外，读取旧配置时不改变站点的其他字段。
        switch rawValue {
        case "japan", "海外", "其他海外": self.rawValue = "overseas"
        case "国内", "中国大陆": self.rawValue = "mainland"
        default: self.rawValue = rawValue
        }
    }

    public static let mainland = SiteGroup(rawValue: "mainland")
    public static let overseas = SiteGroup(rawValue: "overseas")
    public static let intranet = SiteGroup(rawValue: "intranet")
    public static let tailnet = SiteGroup(rawValue: "tailnet")
    /// 旧调用方的兼容别名；不再是独立分组。
    public static let japan = overseas
    public static let allCases: [SiteGroup] = [.mainland, .overseas, .intranet, .tailnet]

    /// 按条件参与探测的特殊分组（VPN 站点、Tailnet 子网），不属于公开组。
    public var isConditional: Bool { self == .intranet || self == .tailnet }

    public var displayName: String {
        switch self {
        case .mainland: return "国内"
        case .overseas: return "海外"
        case .intranet: return "VPN 站点"
        case .tailnet: return "Tailnet 子网"
        default: return rawValue
        }
    }

    /// 已启用公开组按站点首次出现的顺序显示，不显示空组。
    public static func publicGroups(for sites: [Site]) -> [SiteGroup] {
        var groups: [SiteGroup] = []
        for site in sites where site.isEnabled && !site.group.isConditional && !groups.contains(site.group) {
            groups.append(site.group)
        }
        return groups
    }

    /// 公开组名的统一约束；VPN 站点和 Tailnet 子网由各自的决策单独管理。
    public var isValidPublicGroup: Bool {
        let name = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 20 && name == rawValue && !isConditional &&
            name != SiteGroup.intranet.displayName && name != SiteGroup.tailnet.displayName &&
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 一个探测站点。
public struct Site: Sendable, Hashable, Identifiable, Codable {
    /// 稳定 ID，也用于故障键（`site.<id>`），例如 `google`。
    public var id: String
    public var name: String
    public var group: SiteGroup
    public var url: URL
    /// 是否为关键站点（参与告警计数）。
    public var isKey: Bool
    /// 是否参与后台轻测。
    public var inLightProbe: Bool
    /// 禁用后不参与探测、告警和当前诊断展示。
    public var isEnabled: Bool

    public init(id: String, name: String, group: SiteGroup, url: URL, isKey: Bool, inLightProbe: Bool,
                isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.group = group
        self.url = url
        self.isKey = isKey
        self.inLightProbe = inLightProbe
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey { case id, name, group, url, isKey, inLightProbe, isEnabled }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        group = try values.decode(SiteGroup.self, forKey: .group)
        url = try values.decode(URL.self, forKey: .url)
        isKey = try values.decode(Bool.self, forKey: .isKey)
        inLightProbe = try values.decode(Bool.self, forKey: .inLightProbe)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// VPN 站点探测决策。
public enum IntranetProbeDecision: Sendable, Equatable {
    /// VPN 已连接且已配置：参与探测。
    case probe(Site)
    /// 未配置 VPN 站点 URL：显示“未验证”。
    case notConfigured
    /// VPN 断开：不探测，显示“未连接 VPN”，不计入故障。
    case vpnDisconnected
    /// VPN 切换中或未确认：不探测。
    case vpnUnconfirmed

    public var site: Site? {
        if case .probe(let site) = self { return site }
        return nil
    }

    /// 不探测时的展示文本。
    public var skippedText: String? {
        switch self {
        case .probe: return nil
        case .notConfigured: return "未验证"
        case .vpnDisconnected: return "未连接 VPN"
        case .vpnUnconfirmed: return "VPN 状态未确认"
        }
    }
}

/// Tailnet 子网探测决策：按 Tailnet 卡的路由判断决定是否探测。
public enum TailnetProbeDecision: Sendable, Equatable {
    /// 目标经 Tailscale 隧道路由：参与探测。
    case probe(Site)
    /// 未配置 Tailnet 子网目标。
    case notConfigured
    /// 没有 Tailscale 隧道：不探测，不计入故障。
    case tailscaleDown
    /// 目标落在当前网络的网段内（人就在该局域网里，或所在网络恰好同网段）：不探测，不计入故障。
    case sameSubnet
    /// 子网路由没有指向 Tailscale：不探测，由 Tailnet 卡报告。
    case routeUnavailable
    /// 路由表未采集或处于切换中：不探测。
    case unconfirmed

    public var site: Site? {
        if case .probe(let site) = self { return site }
        return nil
    }

    /// 不探测时的展示文本。
    public var skippedText: String? {
        switch self {
        case .probe: return nil
        case .notConfigured: return "未配置"
        case .tailscaleDown: return "未连接 Tailscale"
        case .sameSubnet: return "当前网络与 Tailnet 子网网段相同"
        case .routeUnavailable: return "子网路由未生效"
        case .unconfirmed: return "路由未确认"
        }
    }

    /// JSON 中的状态值。
    public var statusValue: String {
        switch self {
        case .probe: return "probed"
        case .notConfigured: return "notConfigured"
        case .tailscaleDown: return "tailscaleDown"
        case .sameSubnet: return "sameSubnet"
        case .routeUnavailable: return "routeUnavailable"
        case .unconfirmed: return "unconfirmed"
        }
    }
}

/// 内置站点：默认清单与可一键添加的常用站点模板。
public enum SiteCatalog {
    private static func make(_ id: String, _ name: String, _ group: SiteGroup, _ url: String,
                             key: Bool = false, light: Bool = false) -> Site {
        Site(id: id, name: name, group: group, url: URL(string: url)!, isKey: key, inLightProbe: light)
    }

    public static let baidu = make("baidu", "百度", .mainland, "https://www.baidu.com/", key: true, light: true)
    public static let bilibili = make("bilibili", "哔哩哔哩", .mainland, "https://www.bilibili.com/")
    public static let jd = make("jd", "京东", .mainland, "https://www.jd.com/")
    public static let yahooJapan = make("yahooJapan", "Yahoo! Japan", .overseas, "https://www.yahoo.co.jp/")
    public static let sony = make("sony", "Sony", .overseas, "https://www.sony.co.jp/")
    public static let google = make("google", "Google", .overseas, "https://www.google.com/generate_204", key: true, light: true)
    public static let github = make("github", "GitHub", .overseas, "https://github.com/", key: true, light: true)
    public static let cloudflare = make("cloudflare", "Cloudflare", .overseas, "https://www.cloudflare.com/")
    public static let claude = make("claude", "Claude", .overseas, "https://claude.ai/")
    public static let chatgpt = make("chatgpt", "ChatGPT", .overseas, "https://chatgpt.com/")

    /// VPN 站点 ID。
    public static let intranetID = "intranet"

    /// VPN 站点（关键；仅在 VPN 已连接时参与轻测）。名称固定，不含 URL。
    public static func intranet(url: URL) -> Site {
        Site(id: intranetID, name: "VPN 站点", group: .intranet, url: url, isKey: true, inLightProbe: true)
    }

    /// Tailnet 子网站点 ID。
    public static let tailnetID = "tailnet"

    /// Tailnet 子网（关键；只在目标经 Tailscale 路由时参与轻测）。URL 形如 `tcp://192.0.2.10:443`，做 TCP 连接探测。
    public static func tailnet(target: TailnetTarget) -> Site {
        Site(id: tailnetID, name: "Tailnet 子网", group: .tailnet, url: target.url, isKey: true, inLightProbe: true)
    }

    /// 默认公开站点。后台检测与告警：百度、Google、GitHub。
    public static let defaultSites: [Site] = [baidu, bilibili, google, github, cloudflare]

    /// 设置页“添加常用站点”的模板，按分组排列。
    public static let templates: [Site] = [baidu, bilibili, jd, google, github, cloudflare, yahooJapan, sony, claude, chatgpt]

    /// VPN 站点探测决策：只在 VPN 已连接且已配置时探测。
    public static func intranetDecision(intranetURL: URL?, vpnState: VPNConnectionState) -> IntranetProbeDecision {
        guard let url = intranetURL else { return .notConfigured }
        switch vpnState {
        case .connected: return .probe(intranet(url: url))
        case .disconnected: return .vpnDisconnected
        case .switching, .unconfirmed: return .vpnUnconfirmed
        }
    }

    /// 后台轻测站点：设为后台检测的已启用站点，加上满足条件的 VPN 站点和 Tailnet 子网。
    public static func lightProbeSites(intranet decision: IntranetProbeDecision,
                                       tailnet: TailnetProbeDecision = .notConfigured,
                                       sites: [Site] = defaultSites) -> [Site] {
        sites.filter { $0.isEnabled && !$0.group.isConditional && $0.inLightProbe }
            + (decision.site.map { [$0] } ?? []) + (tailnet.site.map { [$0] } ?? [])
    }

    /// 手动完整检测站点：全部已启用站点，加上满足条件的 VPN 站点和 Tailnet 子网。
    public static func fullCheckSites(intranet decision: IntranetProbeDecision,
                                      tailnet: TailnetProbeDecision = .notConfigured,
                                      sites: [Site] = defaultSites) -> [Site] {
        sites.filter { $0.isEnabled && !$0.group.isConditional }
            + (decision.site.map { [$0] } ?? []) + (tailnet.site.map { [$0] } ?? [])
    }
}
