import Foundation

/// 家庭子网探测目标：一个 IPv4 地址和 TCP 端口，例如 `192.0.2.10:443`。
public struct TailnetTarget: Sendable, Hashable, Codable, CustomStringConvertible {
    public var address: IPv4
    public var port: Int

    public init?(address: IPv4, port: Int) {
        guard (1...65535).contains(port) else { return nil }
        self.address = address
        self.port = port
    }

    /// 解析 `a.b.c.d:port`。只接受 IPv4 字面量：判断走哪条路由需要确定的地址。
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let address = IPv4(String(parts[0])),
              let port = Int(parts[1]), String(port) == parts[1] else { return nil }
        self.init(address: address, port: port)
    }

    public var description: String { "\(address):\(port)" }

    /// 探测站点使用的 URL，形如 `tcp://192.0.2.10:443`。
    public var url: URL { URL(string: "tcp://\(description)")! }

    /// 从探测站点的 URL 还原目标；不是 `tcp://地址:端口` 时为 nil。
    public init?(url: URL) {
        guard url.scheme == "tcp", let host = url.host, let port = url.port,
              let address = IPv4(host) else { return nil }
        self.init(address: address, port: port)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let target = TailnetTarget(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "家庭子网目标无效：\(text)")
        }
        self = target
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// 路由表查询。
public enum RouteLookup {
    /// 目标地址实际使用的路由：在非限定作用域（flags 不含 `I`）且已启用（含 `U`）的路由中做最长前缀匹配。
    /// 限定作用域的路由只对绑定了该接口的连接生效，不代表默认走向。
    public static func bestRoute(for address: IPv4, in routes: [RouteEntry]) -> RouteEntry? {
        var best: (route: RouteEntry, prefix: Int)?
        for route in routes {
            guard route.flags.contains("U"), !route.flags.contains("I"),
                  let network = route.network, network.contains(address) else { continue }
            if best == nil || network.prefixLength > best!.prefix {
                best = (route, network.prefixLength)
            }
        }
        return best?.route
    }
}

/// MagicDNS 反查（PTR）的结果。
public enum MagicDNSReverseResult: Sendable, Equatable {
    /// 收到应答。`name` 为本机的 MagicDNS 名称（去掉末尾的点）；没有 PTR 记录时为 nil。
    case answered(name: String?)
    case timedOut
    case failed(reason: String)
}

/// Tailscale 相关的采集结果。只在存在 Tailscale 隧道时采集。
public struct TailnetProbeSnapshot: Sendable, Equatable {
    /// 本机的 Tailscale 地址，反查用。
    public var selfAddress: IPv4
    /// 向 MagicDNS（`100.100.100.100`）反查本机地址的结果。
    public var reverse: MagicDNSReverseResult
    /// 用系统解析器正向解析反查得到的名称；没有名称时为 nil。
    public var forward: CanaryResult?

    public init(selfAddress: IPv4, reverse: MagicDNSReverseResult, forward: CanaryResult? = nil) {
        self.selfAddress = selfAddress
        self.reverse = reverse
        self.forward = forward
    }
}

/// Tailnet 判定：Tailscale 隧道、tailnet 路由、MagicDNS，以及家庭子网目标的路由走向。
struct TailnetAnalysis {
    /// Tailnet 卡；没有 Tailscale 隧道且没配置目标时为 nil。
    var card: StatusCard?
    var decision: TailnetProbeDecision

    static let magicDNSAddress = "100.100.100.100"
    static let title = "Tailnet"

    /// Tailscale 隧道：UP、IPv4 位于 `100.64.0.0/10` 的 utun。
    static func tailscaleInterface(_ interfaces: [InterfaceInfo]) -> InterfaceInfo? {
        interfaces.first { $0.isTunnel && $0.isUp && $0.ipv4Addresses.contains(where: IPv4CIDR.tailscale.contains) }
    }

    static func analyze(_ snapshot: LocalSnapshot, target: TailnetTarget?,
                        proxyInterface: String?, fakeIPRange: IPv4CIDR?) -> TailnetAnalysis {
        let site = target.map { SiteCatalog.tailnet(target: $0) }
        func card(_ severity: Severity, _ conclusion: String, hint: String? = nil,
                  evidence: [String] = [], key: FaultKey? = nil) -> StatusCard {
            StatusCard(kind: .tailnet, title: title, severity: severity, conclusion: conclusion,
                       hint: hint, evidence: evidence, faultKey: key)
        }

        guard let interfaces = snapshot.interfaces.value else {
            guard target != nil else { return TailnetAnalysis(card: nil, decision: .notConfigured) }
            let reason = snapshot.interfaces.failureReason.map { "（\($0)）" } ?? ""
            return TailnetAnalysis(card: card(.unknown, "证据不足：未能读取网络接口\(reason)"),
                                   decision: .unconfirmed)
        }
        guard let tunnel = tailscaleInterface(interfaces) else {
            guard target != nil else { return TailnetAnalysis(card: nil, decision: .notConfigured) }
            return TailnetAnalysis(card: card(.unknown, "未连接 Tailscale",
                                              evidence: ["没有 IPv4 位于 \(IPv4CIDR.tailscale) 的 UP utun"]),
                                   decision: .tailscaleDown)
        }

        let addresses = tunnel.ipv4Addresses.filter(IPv4CIDR.tailscale.contains)
        var evidence = ["Tailscale 隧道 \(tunnel.name)（\(addresses.map(\.description).joined(separator: ", "))）"]
        guard let routes = snapshot.routes.value else {
            let reason = snapshot.routes.failureReason.map { "（\($0)）" } ?? ""
            return TailnetAnalysis(card: card(.unknown, "证据不足：未能读取路由表\(reason)", evidence: evidence),
                                   decision: target == nil ? .notConfigured : .unconfirmed)
        }

        func describe(_ route: RouteEntry?) -> String {
            guard let route else { return "没有匹配的路由" }
            if route.interfaceName == tunnel.name { return "\(route.interfaceName)（Tailscale）" }
            if route.interfaceName == proxyInterface { return "\(route.interfaceName)（代理 TUN）" }
            return route.interfaceName
        }

        // 1. tailnet 本身的路由：MagicDNS 地址与 100.64/10 网段都应走 Tailscale 隧道。
        // 路由表里完全没有匹配项（连默认路由都没有）只会出现在采集不全时，判为证据不足。
        var routeProblems: [String] = []
        var unmatched: [String] = []
        for (label, address) in [("MagicDNS 地址", IPv4(magicDNSAddress)!), ("tailnet 网段", IPv4(100, 64, 0, 1))] {
            guard let route = RouteLookup.bestRoute(for: address, in: routes) else {
                unmatched.append(label)
                continue
            }
            if route.interfaceName != tunnel.name {
                routeProblems.append("\(label)经 \(describe(route))，不是 \(tunnel.name)")
            }
        }
        if routeProblems.isEmpty && !unmatched.isEmpty {
            evidence.append("路由表中没有\(unmatched.joined(separator: "、"))的路由")
            return TailnetAnalysis(card: card(.unknown, "证据不足：路由表不完整", evidence: evidence),
                                   decision: target == nil ? .notConfigured : .unconfirmed)
        }
        if !routeProblems.isEmpty {
            evidence += routeProblems
            return TailnetAnalysis(
                card: card(.critical, "tailnet 路由没有指向 Tailscale 隧道",
                           hint: "检查代理 TUN 的路由排除设置，确认 100.64.0.0/10 不经过代理",
                           evidence: evidence, key: .tailnetRoute),
                decision: target == nil ? .notConfigured : .routeUnavailable)
        }
        evidence.append("tailnet 路由经 \(tunnel.name)")

        // 2. MagicDNS：只在系统配置了指向 100.100.100.100 的解析器时检查。
        // 证据中不写 MagicDNS 名称和 tailnet 域名：它们能识别设备和 tailnet。
        var magicDNSProblem: String?
        var magicDNSVerified = false
        let magicResolver = snapshot.resolvers.value?.first {
            $0.nameservers.contains(magicDNSAddress) && $0.domain != nil
        }
        if magicResolver != nil {
            switch snapshot.tailnet {
            case .collected(let probe):
                switch probe.reverse {
                case .timedOut:
                    magicDNSProblem = "MagicDNS 无响应（反查超时）"
                case .failed(let reason):
                    magicDNSProblem = "MagicDNS 查询失败（\(reason)）"
                case .answered(name: nil):
                    evidence.append("MagicDNS 有响应，但没有返回本机名称，跳过名称解析检查")
                case .answered(name: .some):
                    switch probe.forward {
                    case .resolved(let ips) where ips.contains(probe.selfAddress):
                        magicDNSVerified = true
                        evidence.append("系统解析本机 MagicDNS 名称，返回本机 Tailscale 地址")
                    case .resolved(let ips) where !ips.isEmpty
                        && ips.allSatisfy({ fakeIPRange?.contains($0) ?? IPv4CIDR.benchmarkFakeIP.contains($0) }):
                        magicDNSProblem = "MagicDNS 名称被代理截获，解析为 fake-ip \(ips.map(\.description).joined(separator: ", "))"
                    case .resolved(let ips) where !ips.isEmpty:
                        magicDNSProblem = "MagicDNS 名称解析为 \(ips.map(\.description).joined(separator: ", "))，与本机 Tailscale 地址不符"
                    case .resolved:
                        magicDNSProblem = "系统解析 MagicDNS 名称没有返回地址"
                    case .failed(let reason):
                        magicDNSProblem = "系统无法解析 MagicDNS 名称（\(reason)）"
                    case .notTested, nil:
                        evidence.append("MagicDNS 有响应，名称解析未检查")
                    }
                }
            case .failed(let reason):
                evidence.append("MagicDNS 未检查（\(reason)）")
            case .notCollected:
                evidence.append("MagicDNS 未检查")
            }
        } else if snapshot.resolvers.isCollected {
            evidence.append("未启用 MagicDNS（没有指向 \(magicDNSAddress) 的解析器）")
        }
        if let problem = magicDNSProblem { evidence.append(problem) }

        // 3. 家庭子网目标的走向。
        var decision: TailnetProbeDecision = .notConfigured
        var subnetProblem: String?
        var sameSubnet = false
        if let target, let site {
            let route = RouteLookup.bestRoute(for: target.address, in: routes)
            if route?.interfaceName == tunnel.name {
                decision = .probe(site)
                evidence.append("家庭子网 \(target.address) 经 \(describe(route))")
            } else if let route, !route.interfaceName.hasPrefix("utun"), !route.isDefault, !route.flags.contains("G") {
                // 直连网段（没有网关）：目标就在当前网络里。经网关或默认路由出去则说明子网路由没有生效。
                decision = .sameSubnet
                sameSubnet = true
                evidence.append("家庭子网 \(target.address) 经 \(route.interfaceName)，与当前网络网段相同")
            } else {
                decision = .routeUnavailable
                subnetProblem = "家庭子网 \(target.address) 经 \(describe(route))，子网路由未生效"
                evidence.append(subnetProblem!)
            }
        }

        let result: StatusCard
        if let subnetProblem {
            result = card(.critical, subnetProblem,
                          hint: "确认 Tailscale 已接受子网路由，且路由节点在线", evidence: evidence, key: .tailnetSubnetRoute)
        } else if let magicDNSProblem {
            result = card(.warning, magicDNSProblem,
                          hint: "按名称访问 tailnet 设备可能失败；按 IP 访问不受影响。检查代理的 fake-ip 过滤名单是否包含 *.ts.net",
                          evidence: evidence, key: .tailnetMagicDNS)
        } else if sameSubnet {
            result = card(.unknown, "当前网络与家庭子网网段相同，不探测", evidence: evidence)
        } else {
            let magic = magicDNSVerified ? "，MagicDNS 正常" : ""
            result = card(.ok, "已连接（\(tunnel.name)）\(magic)", evidence: evidence)
        }
        return TailnetAnalysis(card: result, decision: decision)
    }
}
