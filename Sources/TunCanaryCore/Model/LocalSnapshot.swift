import Foundation

/// 一项采集结果：未采集、采集失败（带原因）或已采集。
public enum Collected<Value: Sendable & Equatable>: Sendable, Equatable {
    case notCollected
    case failed(reason: String)
    case collected(Value)

    /// 已采集时的值。
    public var value: Value? {
        if case .collected(let value) = self { return value }
        return nil
    }

    /// 采集失败的原因。
    public var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }

    public var isCollected: Bool { value != nil }

    public func map<T: Sendable & Equatable>(_ transform: (Value) -> T) -> Collected<T> {
        switch self {
        case .notCollected: return .notCollected
        case .failed(let reason): return .failed(reason: reason)
        case .collected(let value): return .collected(transform(value))
        }
    }
}

/// 进程条目：pid 与可执行文件路径（proc_pidpath）。
public struct ProcessEntry: Sendable, Equatable, Hashable {
    public var pid: Int32
    /// 可执行文件完整路径；取不到时为 nil。
    public var executablePath: String?
    /// 命令行，仅供诊断和测试。判定不使用：临时进程（如 grep）的命令行可能含有同样的字样。
    public var commandLine: String?

    public init(pid: Int32, executablePath: String?, commandLine: String? = nil) {
        self.pid = pid
        self.executablePath = executablePath
        self.commandLine = commandLine
    }

    /// 可执行文件名，例如 `verge-mihomo`。
    public var executableName: String? {
        guard let path = executablePath, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }
}

/// 网络接口。
public struct InterfaceInfo: Sendable, Equatable {
    public var name: String
    /// 是否带 UP 标志。
    public var isUp: Bool
    public var ipv4Addresses: [IPv4]
    /// 原始标志，例如 `["UP", "POINTOPOINT", "RUNNING"]`。
    public var flags: [String]

    public init(name: String, isUp: Bool, ipv4Addresses: [IPv4] = [], flags: [String] = []) {
        self.name = name
        self.isUp = isUp
        self.ipv4Addresses = ipv4Addresses
        self.flags = flags
    }

    /// 是否为 utun 隧道接口。
    public var isTunnel: Bool { name.hasPrefix("utun") }
}

/// IPv4 路由表条目。
public struct RouteEntry: Sendable, Equatable {
    /// 原始目的地写法，例如 `default`、`10.231/16`。
    public var destination: String
    public var gateway: String
    public var flags: String
    /// 出接口，例如 `utun9`。
    public var interfaceName: String
    /// 解析后的网段；`default` 为 0.0.0.0/0；无法解析时为 nil。
    public var network: IPv4CIDR?

    public init(destination: String, gateway: String, flags: String = "", interfaceName: String, network: IPv4CIDR? = nil) {
        self.destination = destination
        self.gateway = gateway
        self.flags = flags
        self.interfaceName = interfaceName
        self.network = network ?? IPv4CIDR(netstatDestination: destination)
    }

    public var isDefault: Bool { destination == "default" }
}

/// `scutil --dns` 中的一个解析器。
public struct Resolver: Sendable, Equatable {
    /// 是否位于 “DNS configuration (for scoped queries)” 段。
    public var isScoped: Bool
    /// `resolver #n` 中的 n。
    public var number: Int
    public var domain: String?
    public var searchDomains: [String]
    public var nameservers: [String]
    public var ifIndex: Int?
    /// if_index 括号中的接口名，例如 `en0`。
    public var interfaceName: String?
    public var flags: [String]
    public var order: Int?

    public init(
        isScoped: Bool,
        number: Int,
        domain: String? = nil,
        searchDomains: [String] = [],
        nameservers: [String] = [],
        ifIndex: Int? = nil,
        interfaceName: String? = nil,
        flags: [String] = [],
        order: Int? = nil
    ) {
        self.isScoped = isScoped
        self.number = number
        self.domain = domain
        self.searchDomains = searchDomains
        self.nameservers = nameservers
        self.ifIndex = ifIndex
        self.interfaceName = interfaceName
        self.flags = flags
        self.order = order
    }
}

/// 主网络服务（由 `State:/Network/Global/IPv4` 的 PrimaryService 确定）。
public struct PrimaryServiceInfo: Sendable, Equatable {
    public var serviceID: String
    /// 服务名，例如 “Wi-Fi”；取不到时为 nil。
    public var name: String?
    /// 接口名，例如 `en0`。
    public var interfaceName: String?
    /// 保存的 DNS（`Setup:/Network/Service/<id>/DNS`），已去掉空字符串。
    public var savedDNS: [String]
    /// 服务的 State DNS（通常为 DHCP 下发）。
    public var stateDNS: [String]

    public init(serviceID: String, name: String?, interfaceName: String?, savedDNS: [String], stateDNS: [String]) {
        self.serviceID = serviceID
        self.name = name
        self.interfaceName = interfaceName
        self.savedDNS = DNSList.normalize(savedDNS)
        self.stateDNS = DNSList.normalize(stateDNS)
    }
}

/// 向 `127.0.0.1:<dns.listen 端口>` 发送 UDP A 查询的结果。
public enum MihomoDNSProbeResult: Sendable, Equatable {
    case notCollected
    /// 不适用（如 TUN 关闭、配置中没有端口）。
    case notApplicable
    /// 超时或端口拒绝。
    case noResponse(port: Int)
    /// 收到应答。延迟单位为秒。
    case success(port: Int, latency: TimeInterval, answers: [IPv4])
}

/// 通过系统解析器查询 canary 域名（`www.google.com`）的结果。
public enum CanaryResult: Sendable, Equatable {
    case notTested
    case failed(reason: String)
    case resolved([IPv4])
}

/// 通过系统解析器查询 canary 域名 AAAA 记录的结果。只作证据，不参与判定。
public enum CanaryIPv6Result: Sendable, Equatable {
    case notTested
    case failed(reason: String)
    /// 没有 AAAA 记录（`EAI_NONAME`/`EAI_NODATA`），常见且正常。
    case noRecord
    case resolved([IPv6])
}

/// 一轮本机状态采集结果。每个字段都能表示“未采集”或“失败”。
public struct LocalSnapshot: Sendable, Equatable {
    public var collectedAt: Date
    /// Clash Verge 配置；读取失败时为 `.failed`（带具体原因）。
    public var clashConfig: Collected<ClashConfig>
    /// `verge-mihomo` 是否在运行。
    public var mihomoRunning: Collected<Bool>
    /// 相关进程（至少包含可执行文件路径匹配 VPN 适配器与 verge-mihomo 的进程）。
    public var processes: Collected<[ProcessEntry]>
    public var interfaces: Collected<[InterfaceInfo]>
    public var routes: Collected<[RouteEntry]>
    public var resolvers: Collected<[Resolver]>
    /// 各 VPN 适配器状态文件的读取结果，键为适配器 ID。缺少的键视为未采集。
    public var vpnStatusFiles: [String: VPNStatusFileState]
    public var primaryService: Collected<PrimaryServiceInfo>
    /// 全局生效 DNS（`State:/Network/Global/DNS`），已去掉空字符串。
    public var globalDNS: Collected<[String]>
    public var mihomoDNS: MihomoDNSProbeResult
    public var canary: CanaryResult
    /// 同一域名的 AAAA 查询结果。
    public var canaryIPv6: CanaryIPv6Result
    /// 本轮系统解析 canary 查询的域名。
    public var canaryHost: String
    /// DNS 守护进程的安装情况、配置和状态。只用于展示，不参与判定。
    public var dnsGuard: Collected<DNSGuardSnapshot>

    public init(
        collectedAt: Date,
        clashConfig: Collected<ClashConfig> = .notCollected,
        mihomoRunning: Collected<Bool> = .notCollected,
        processes: Collected<[ProcessEntry]> = .notCollected,
        interfaces: Collected<[InterfaceInfo]> = .notCollected,
        routes: Collected<[RouteEntry]> = .notCollected,
        resolvers: Collected<[Resolver]> = .notCollected,
        vpnStatusFiles: [String: VPNStatusFileState] = [:],
        primaryService: Collected<PrimaryServiceInfo> = .notCollected,
        globalDNS: Collected<[String]> = .notCollected,
        mihomoDNS: MihomoDNSProbeResult = .notCollected,
        canary: CanaryResult = .notTested,
        canaryIPv6: CanaryIPv6Result = .notTested,
        canaryHost: String = PulseConstants.canaryHost,
        dnsGuard: Collected<DNSGuardSnapshot> = .notCollected
    ) {
        self.collectedAt = collectedAt
        self.clashConfig = clashConfig
        self.mihomoRunning = mihomoRunning
        self.processes = processes
        self.interfaces = interfaces
        self.routes = routes
        self.resolvers = resolvers
        self.vpnStatusFiles = vpnStatusFiles
        self.primaryService = primaryService
        self.globalDNS = globalDNS.map { DNSList.normalize($0) }
        self.mihomoDNS = mihomoDNS
        self.canary = canary
        self.canaryIPv6 = canaryIPv6
        self.canaryHost = canaryHost
        self.dnsGuard = dnsGuard
    }

    /// verge-mihomo 是否运行：优先用 `mihomoRunning`，未采集时从进程列表推断。
    public var effectiveMihomoRunning: Bool? {
        if let running = mihomoRunning.value { return running }
        if let list = processes.value {
            return list.contains { $0.executableName == KnownPaths.mihomoProcessName }
        }
        return nil
    }

    /// 生效 DNS：优先 `State:/Network/Global/DNS`，否则取默认解析器（非 scoped、无 domain 的第一个）。
    public var effectiveDNS: [String]? {
        if let global = globalDNS.value { return DNSList.normalize(global) }
        if let resolvers = resolvers.value,
           let first = resolvers.first(where: { !$0.isScoped && $0.domain == nil && !$0.nameservers.isEmpty }) {
            return DNSList.normalize(first.nameservers)
        }
        return nil
    }
}
