import Foundation

/// DNS 守护进程的配置（`/Library/Application Support/TunCanary/dns-guard.json`，归 root 所有）。
///
/// 目标 DNS、内网探针域名等本机值只写在这个文件里。安装脚本按当前登录用户生成，之后修改需要 `sudo`。
public struct DNSGuardConfig: Sendable, Equatable, Codable {
    /// 连接期接管（阶段 B）。
    public struct ConnectedTakeover: Sendable, Equatable, Codable {
        public var enabled: Bool
        /// 通过代理 DNS 查询的内网域名。查到真实地址，说明代理能解析内网域名。
        public var intranetProbeHost: String
        /// 10 分钟内最多写入几次。达到上限说明 VPN 客户端在反复改回自己的 DNS，停用接管直到 VPN 断开。
        public var maxWritesPerTenMinutes: Int

        public init(enabled: Bool = false, intranetProbeHost: String = "", maxWritesPerTenMinutes: Int = 3) {
            self.enabled = enabled
            self.intranetProbeHost = intranetProbeHost
            self.maxWritesPerTenMinutes = maxWritesPerTenMinutes
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, intranetProbeHost, maxWritesPerTenMinutes
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            intranetProbeHost = try values.decodeIfPresent(String.self, forKey: .intranetProbeHost) ?? ""
            maxWritesPerTenMinutes = try values.decodeIfPresent(Int.self, forKey: .maxWritesPerTenMinutes) ?? 3
        }
    }

    public static let defaultServiceTypes = ["IEEE80211", "Ethernet"]
    /// 永远不写入的服务类型：VPN 与点对点服务。
    public static let forbiddenServiceTypes: Set<String> = ["PPP", "IPSec", "VPN", "L2TP", "PPTP"]

    /// 目标 DNS，一个或多个 IPv4。
    public var targetDNS: [String]
    /// 允许写入的服务类型（`SCNetworkInterfaceGetInterfaceType` 的取值）。
    public var allowedServiceTypes: [String]
    /// 登录用户的主目录，用于展开适配器配置中的 `~/`。
    public var homeDirectory: String
    /// 代理配置目录。只读取其中的 TUN 开关、DNS 端口和 fake-ip 网段。
    public var proxyConfigDir: String
    public var connectedTakeover: ConnectedTakeover
    /// 两次采样的间隔（秒）。
    public var sampleDelaySeconds: Double

    public init(targetDNS: [String], allowedServiceTypes: [String] = DNSGuardConfig.defaultServiceTypes,
                homeDirectory: String, proxyConfigDir: String,
                connectedTakeover: ConnectedTakeover = ConnectedTakeover(), sampleDelaySeconds: Double = 3) {
        self.targetDNS = targetDNS
        self.allowedServiceTypes = allowedServiceTypes
        self.homeDirectory = homeDirectory
        self.proxyConfigDir = proxyConfigDir
        self.connectedTakeover = connectedTakeover
        self.sampleDelaySeconds = sampleDelaySeconds
    }

    private enum CodingKeys: String, CodingKey {
        case targetDNS, allowedServiceTypes, homeDirectory, proxyConfigDir, connectedTakeover, sampleDelaySeconds
    }

    /// 必填：`targetDNS`、`homeDirectory`、`proxyConfigDir`；其余缺失时取默认值。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        targetDNS = try values.decode([String].self, forKey: .targetDNS)
        allowedServiceTypes = try values.decodeIfPresent([String].self, forKey: .allowedServiceTypes)
            ?? Self.defaultServiceTypes
        homeDirectory = try values.decode(String.self, forKey: .homeDirectory)
        proxyConfigDir = try values.decode(String.self, forKey: .proxyConfigDir)
        connectedTakeover = try values.decodeIfPresent(ConnectedTakeover.self, forKey: .connectedTakeover)
            ?? ConnectedTakeover()
        sampleDelaySeconds = try values.decodeIfPresent(Double.self, forKey: .sampleDelaySeconds) ?? 3
    }

    /// 规范化后的目标 DNS。
    public var effectiveTargetDNS: [String] { DNSList.normalize(targetDNS) }

    /// 校验，返回全部问题；空数组表示通过。
    public func validate() -> [String] {
        var problems: [String] = []
        let target = effectiveTargetDNS
        if target.isEmpty { problems.append("targetDNS 至少填写一个 IPv4 地址") }
        for item in target where IPv4(item) == nil { problems.append("targetDNS 中的“\(item)”不是 IPv4 地址") }
        if allowedServiceTypes.isEmpty { problems.append("allowedServiceTypes 不能为空") }
        for type in allowedServiceTypes where Self.forbiddenServiceTypes.contains(type) {
            problems.append("allowedServiceTypes 不能包含 VPN 类服务“\(type)”")
        }
        if !homeDirectory.hasPrefix("/") { problems.append("homeDirectory 须为绝对路径") }
        if !proxyConfigDir.hasPrefix("/") { problems.append("proxyConfigDir 须为绝对路径") }
        if !(0...30).contains(sampleDelaySeconds) { problems.append("sampleDelaySeconds 须在 0 至 30 之间") }
        if !(1...20).contains(connectedTakeover.maxWritesPerTenMinutes) {
            problems.append("connectedTakeover.maxWritesPerTenMinutes 须在 1 至 20 之间")
        }
        if connectedTakeover.enabled && !SettingsValidator.isValidHostName(connectedTakeover.intranetProbeHost) {
            problems.append("启用连接期接管时，connectedTakeover.intranetProbeHost 须为有效域名")
        }
        return problems
    }

    public static func parse(_ data: Data) throws -> DNSGuardConfig {
        do {
            return try JSONDecoder().decode(DNSGuardConfig.self, from: data)
        } catch {
            throw DNSGuardFileParser.ParseError(message: "配置不是有效的 JSON，或缺少 targetDNS、homeDirectory、proxyConfigDir")
        }
    }

    /// 格式化输出（键排序、缩进），供安装脚本生成配置文件。
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }
}
