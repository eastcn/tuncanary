import Foundation

/// 故障键，用于通知去重，例如 `dns.notRestored`、`site.google`、`group.overseas`。
public struct FaultKey: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public var description: String { rawValue }

    public static func < (lhs: FaultKey, rhs: FaultKey) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // MARK: 本机

    /// VPN 断开、TUN 运行，但主网络 DNS 未恢复为预期值（红）。
    public static let dnsNotRestored: FaultKey = "dns.notRestored"
    /// VPN 已连接，但主网络 DNS 不是 VPN 下发的 DNS（黄）。
    public static let dnsVPNMissing: FaultKey = "dns.vpnDNSMissing"
    /// 连接期规则为“由代理接管”：VPN 已连接、TUN 运行，但主网络 DNS 不符合断开期规则，查询绕过代理（红）。
    public static let dnsNotTakenOver: FaultKey = "dns.notTakenOver"
    /// TUN 以 fake-ip 模式运行，但系统解析返回真实地址，DNS 绕过了代理（红）。
    public static let dnsBypassProxy: FaultKey = "dns.bypassProxy"
    /// TUN 关闭，但主网络 DNS 仍含预期 DNS（黄）。
    public static let dnsResidual: FaultKey = "dns.residual"
    /// TUN 配置开启，但隧道接口不存在或 verge-mihomo 未运行（黄）。
    public static let tunInactive: FaultKey = "tun.inactive"
    /// TUN 运行，但 Mihomo DNS 无响应（黄）。
    public static let mihomoNoResponse: FaultKey = "mihomo.noResponse"
    /// Tailscale 隧道存在，但 MagicDNS 地址或 tailnet 网段的路由没有指向它（红）。
    public static let tailnetRoute: FaultKey = "tailnet.route"
    /// 家庭子网目标没有经 Tailscale 路由，也不在当前网络的网段内（红）。
    public static let tailnetSubnetRoute: FaultKey = "tailnet.subnetRoute"
    /// MagicDNS 无响应，或者系统解析 MagicDNS 名称出错（黄）。
    public static let tailnetMagicDNS: FaultKey = "tailnet.magicDNS"

    // MARK: 连通性

    /// 单站故障键，例如 `site.google`。
    public static func site(_ siteID: String) -> FaultKey {
        FaultKey(rawValue: "site." + siteID)
    }

    /// 分组故障键，例如 `group.overseas`。
    public static func group(_ group: SiteGroup) -> FaultKey {
        FaultKey(rawValue: "group." + group.rawValue)
    }
}

/// 一个处于黄或红状态的故障。
public struct Fault: Hashable, Sendable {
    public var key: FaultKey
    public var severity: Severity
    /// 一句话描述，例如 “主网络 DNS（Wi-Fi）：VPN 已断开、TUN 运行中，DNS 未恢复为 223.5.5.5”。
    public var message: String
    /// 处理提示，例如 “等待 VPN 完全断开后，关闭并重新开启 Clash TUN”。
    public var hint: String?

    public init(key: FaultKey, severity: Severity, message: String, hint: String? = nil) {
        self.key = key
        self.severity = severity
        self.message = message
        self.hint = hint
    }
}
