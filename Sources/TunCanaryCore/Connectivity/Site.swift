import Foundation

/// 公开站点分组。自定义组以组名为标识；`intranet` 专供 VPN 门槛下的内网站点。
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
    /// 旧调用方的兼容别名；不再是独立分组。
    public static let japan = overseas
    public static let allCases: [SiteGroup] = [.mainland, .overseas, .intranet]

    public var displayName: String {
        switch self {
        case .mainland: return "国内"
        case .overseas: return "海外"
        case .intranet: return "内网站点"
        default: return rawValue
        }
    }

    /// 已启用公开组按站点首次出现的顺序显示，不显示空组。
    public static func publicGroups(for sites: [Site]) -> [SiteGroup] {
        var groups: [SiteGroup] = []
        for site in sites where site.isEnabled && site.group != .intranet && !groups.contains(site.group) {
            groups.append(site.group)
        }
        return groups
    }

    /// 公开组名的统一约束；内网站点始终由 VPN 决策单独管理。
    public var isValidPublicGroup: Bool {
        let name = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 20 && name == rawValue &&
            self != .intranet && name != SiteGroup.intranet.displayName &&
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

/// 内网站点探测决策。
public enum IntranetProbeDecision: Sendable, Equatable {
    /// VPN 已连接且已配置：参与探测。
    case probe(Site)
    /// 未配置内网 URL：显示“未验证”。
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

    /// 内网站点 ID。
    public static let intranetID = "intranet"

    /// 内网站点（关键；仅在 VPN 已连接时参与轻测）。名称固定，不含 URL。
    public static func intranet(url: URL) -> Site {
        Site(id: intranetID, name: "内网站点", group: .intranet, url: url, isKey: true, inLightProbe: true)
    }

    /// 默认公开站点。后台检测与告警：百度、Google、GitHub。
    public static let defaultSites: [Site] = [baidu, bilibili, google, github, cloudflare]

    /// 设置页“添加常用站点”的模板，按分组排列。
    public static let templates: [Site] = [baidu, bilibili, jd, google, github, cloudflare, yahooJapan, sony, claude, chatgpt]

    /// 内网站点探测决策：只在 VPN 已连接且已配置时探测。
    public static func intranetDecision(intranetURL: URL?, vpnState: VPNConnectionState) -> IntranetProbeDecision {
        guard let url = intranetURL else { return .notConfigured }
        switch vpnState {
        case .connected: return .probe(intranet(url: url))
        case .disconnected: return .vpnDisconnected
        case .switching, .unconfirmed: return .vpnUnconfirmed
        }
    }

    /// 后台轻测站点：设为后台检测的已启用站点，加上满足条件的内网。
    public static func lightProbeSites(intranet decision: IntranetProbeDecision,
                                       sites: [Site] = defaultSites) -> [Site] {
        sites.filter { $0.isEnabled && $0.group != .intranet && $0.inLightProbe }
            + (decision.site.map { [$0] } ?? [])
    }

    /// 手动完整检测站点：全部已启用站点，加上满足条件的内网。
    public static func fullCheckSites(intranet decision: IntranetProbeDecision,
                                      sites: [Site] = defaultSites) -> [Site] {
        sites.filter { $0.isEnabled && $0.group != .intranet }
            + (decision.site.map { [$0] } ?? [])
    }
}
