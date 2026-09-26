import Foundation

/// 一个适配器的判定结果。
public struct VPNAdapterAnalysis: Sendable, Equatable {
    public var adapterID: String
    public var name: String
    /// 宽限期外的结论。
    public var state: VPNConnectionState
    public var evidence: [String]
    /// 状态文件中的 VPN DNS（有的客户端断开后仍保留旧值）；未配置或不可读时为空。
    public var statusDNS: [String]
    /// 是否配置了读取 VPN DNS 的字段。
    public var reportsDNS: Bool
    /// 识别出的隧道接口名。
    public var tunnelName: String?
}

/// 全部 VPN 的汇总判定。
public struct VPNAnalysis: Sendable, Equatable {
    /// 宽限期外的汇总结论。
    public var state: VPNConnectionState
    /// 状态卡标题：只有一个适配器时用它的名称，否则为 “VPN”。
    public var title: String
    public var evidence: [String]
    public var adapters: [VPNAdapterAnalysis]
    /// 未被任何适配器认领、也不属于代理 TUN 的隧道。
    public var unrecognizedTunnels: [String]

    /// 已连接的适配器报告的 VPN DNS（去重）。
    public var connectedDNS: [String] {
        DNSList.normalize(adapters.filter { $0.state == .connected }.flatMap(\.statusDNS))
    }

    /// 已连接的适配器中，是否有配置了 VPN DNS 字段的。
    public var connectedReportsDNS: Bool {
        adapters.contains { $0.state == .connected && $0.reportsDNS }
    }

    /// 全部适配器状态文件中的 VPN DNS，用于识别断开后残留的 DNS。
    public var knownDNS: [String] {
        DNSList.normalize(adapters.flatMap(\.statusDNS))
    }

    /// 适配器认领的隧道。
    public var claimedTunnels: Set<String> {
        Set(adapters.compactMap(\.tunnelName))
    }
}

/// 按声明式适配器配置判定 VPN 状态（纯函数）。
public struct VPNAnalyzer: Sendable {
    public var adapters: [VPNAdapterConfig]
    public var homeDirectory: String

    public init(adapters: [VPNAdapterConfig], homeDirectory: String) {
        self.adapters = adapters
        self.homeDirectory = homeDirectory
    }

    /// - Parameters:
    ///   - proxyInterface: 代理 TUN 的接口名，不参与 VPN 隧道识别。
    ///   - fakeIPRange: 代理的 fake-ip 网段，其中的地址不参与 VPN 隧道识别。
    public func analyze(_ snapshot: LocalSnapshot, proxyInterface: String?, fakeIPRange: IPv4CIDR?) -> VPNAnalysis {
        let excluded: (IPv4) -> Bool = { ip in
            (fakeIPRange?.contains(ip) ?? false)
                || IPv4CIDR.benchmarkFakeIP.contains(ip)
                || IPv4CIDR.tailscale.contains(ip)
        }
        var claimed = Set<String>()
        var results: [VPNAdapterAnalysis] = []
        for config in adapters {
            let result = analyzeAdapter(config, snapshot: snapshot, proxyInterface: proxyInterface,
                                        claimed: claimed, excluded: excluded)
            if let name = result.tunnelName { claimed.insert(name) }
            results.append(result)
        }

        let unrecognized = unrecognizedTunnels(snapshot, proxyInterface: proxyInterface,
                                               claimed: claimed, excluded: excluded)
        var evidence: [String] = []
        var state: VPNConnectionState
        if results.isEmpty {
            if snapshot.interfaces.value == nil {
                state = .unconfirmed
                evidence.append("未采集网络接口，无法确认")
            } else if unrecognized.isEmpty {
                state = .disconnected
                evidence.append("未配置 VPN 适配器，也未发现其他 VPN 隧道")
            } else {
                state = .unconfirmed
            }
        } else {
            let states = results.map(\.state)
            if states.contains(.unconfirmed) {
                state = .unconfirmed
            } else if states.contains(.connected) {
                state = .connected
            } else {
                state = .disconnected
            }
            if results.count == 1 {
                evidence = results[0].evidence
            } else {
                for result in results {
                    evidence += result.evidence.map { "\(result.name)：\($0)" }
                }
            }
        }
        if !unrecognized.isEmpty {
            evidence += unrecognized.map(\.evidence)
            if state == .disconnected || results.isEmpty {
                state = .unconfirmed
                evidence.insert("发现未识别的隧道，无法确认 VPN 状态", at: 0)
            }
        }

        return VPNAnalysis(
            state: state,
            title: adapters.count == 1 ? adapters[0].name : "VPN",
            evidence: evidence,
            adapters: results,
            unrecognizedTunnels: unrecognized.map(\.name)
        )
    }

    // MARK: - 单个适配器

    func analyzeAdapter(
        _ config: VPNAdapterConfig,
        snapshot: LocalSnapshot,
        proxyInterface: String?,
        claimed: Set<String>,
        excluded: (IPv4) -> Bool
    ) -> VPNAdapterAnalysis {
        var evidence: [String] = []
        let fileState = snapshot.vpnStatusFiles[config.id] ?? .notCollected
        let status = config.statusFile == nil ? nil : fileState.status

        if config.statusFile != nil {
            switch fileState {
            case .present(let file):
                let text: String
                switch file.status {
                case .some(true): text = "已连接"
                case .some(false): text = "已断开"
                case .none: text = "未记录状态"
                }
                evidence.append("状态文件：\(text)" + (file.connecting == true ? "（连接中）" : ""))
            case .missing:
                evidence.append("状态文件不存在")
            case .unreadable(let reason):
                evidence.append("状态文件不可读：\(reason)")
            case .notCollected:
                evidence.append("未读取状态文件")
            }
        }

        // 进程：按可执行文件路径精确匹配，不看命令行。
        let executables = Set(config.executablePaths(home: homeDirectory))
        var processPresent: Bool?
        if let list = snapshot.processes.value {
            let matches = list.filter { entry in
                guard let path = entry.executablePath else { return false }
                return executables.contains(path)
            }
            processPresent = !matches.isEmpty
            if matches.isEmpty {
                evidence.append("未发现 VPN 进程")
            } else {
                let pids = matches.map { String($0.pid) }.joined(separator: ", ")
                evidence.append("VPN 进程运行中（pid \(pids)）")
            }
        } else {
            evidence.append("未采集进程列表")
        }

        // 隧道：先按状态文件中的隧道 IP，再按配置网段；状态文件没有隧道 IP 时按路由数量回退。
        var tunnel: InterfaceInfo?
        var tunnelDeterminable = false
        var method = ""
        if let interfaces = snapshot.interfaces.value {
            tunnelDeterminable = true
            let candidates = interfaces.filter { iface in
                iface.isTunnel && iface.name != proxyInterface && !claimed.contains(iface.name)
            }
            if let ip = status?.tunnelIPv4 {
                tunnel = candidates.first { $0.ipv4Addresses.contains(ip) }
                method = "按状态文件中的隧道 IP 识别"
            }
            if tunnel == nil, let cidr = config.tunnelNetwork {
                tunnel = candidates.first { iface in
                    iface.ipv4Addresses.contains { cidr.contains($0) && !excluded($0) }
                }
                if tunnel != nil { method = "按配置的隧道网段识别" }
            }
            if tunnel == nil, status?.tunnelIPv4 == nil {
                if let routes = snapshot.routes.value {
                    let ranked = candidates
                        .filter { iface in iface.ipv4Addresses.contains { !excluded($0) } }
                        .map { iface in (iface, routes.filter { $0.interfaceName == iface.name }.count) }
                        .filter { $0.1 >= config.fallbackMinRoutes }
                        .max { $0.1 < $1.1 }
                    tunnel = ranked?.0
                    if tunnel != nil { method = "按路由数量识别" }
                } else if config.tunnelNetwork == nil {
                    tunnelDeterminable = false
                }
            }
        }

        var tunnelUp: Bool?
        var routeCount: Int?
        if tunnelDeterminable {
            tunnelUp = tunnel?.isUp ?? false
            if let routes = snapshot.routes.value {
                routeCount = tunnel.map { t in routes.filter { $0.interfaceName == t.name }.count } ?? 0
            }
        }

        if let t = tunnel {
            let ips = t.ipv4Addresses.map(\.description).joined(separator: ", ")
            evidence.append("隧道 \(t.name) \(t.isUp ? "已启用" : "未启用")（\(ips)，\(method)）")
            if let count = routeCount {
                evidence.append("隧道路由 \(count) 条")
            }
        } else if tunnelDeterminable {
            evidence.append("未发现 VPN 隧道")
        } else {
            evidence.append("未采集网络接口或路由")
        }

        let statusDNS = DNSList.normalize(status?.dnsServers ?? [])
        if !statusDNS.isEmpty {
            evidence.append("VPN DNS（状态文件）：\(DNSList.display(statusDNS))")
        }

        let merged = VPNEvidenceMerger.merge([
            VPNSignal(.required, processPresent),
            VPNSignal(.supporting, tunnelUp),
            VPNSignal(.supporting, routeCount.map { $0 > 0 }),
            VPNSignal(.advisory, status?.status),
        ])
        if let reason = merged.reason {
            evidence.insert(Self.conflictText(reason), at: 0)
        }

        return VPNAdapterAnalysis(
            adapterID: config.id,
            name: config.name,
            state: merged.state,
            evidence: evidence,
            statusDNS: statusDNS,
            reportsDNS: config.statusFile?.dns != nil,
            tunnelName: tunnel?.name
        )
    }

    static func conflictText(_ reason: VPNEvidenceMerger.Reason) -> String {
        switch reason {
        case .requiredUnknown: return "未采集进程列表，无法确认"
        case .supportingUnknown: return "未采集网络接口或路由，无法确认"
        case .requiredWithoutSupport: return "VPN 进程存在，但未发现隧道和隧道路由"
        case .supportWithoutRequired: return "未发现 VPN 进程，但存在隧道或隧道路由"
        case .advisoryContradicts(let claimsConnected):
            return "状态文件显示\(claimsConnected ? "已连接" : "已断开")，与进程和隧道证据矛盾"
        }
    }

    // MARK: - 未识别的隧道

    struct UnrecognizedTunnel {
        var name: String
        var evidence: String
    }

    /// UP、带有不在排除网段内的 IPv4，并且有路由指向的 utun。路由未采集时无法判断，不报告。
    func unrecognizedTunnels(
        _ snapshot: LocalSnapshot,
        proxyInterface: String?,
        claimed: Set<String>,
        excluded: (IPv4) -> Bool
    ) -> [UnrecognizedTunnel] {
        guard let interfaces = snapshot.interfaces.value, let routes = snapshot.routes.value else { return [] }
        return interfaces.compactMap { iface in
            guard iface.isTunnel, iface.isUp, iface.name != proxyInterface, !claimed.contains(iface.name) else { return nil }
            let addresses = iface.ipv4Addresses.filter { !excluded($0) }
            guard !addresses.isEmpty else { return nil }
            let count = routes.filter { $0.interfaceName == iface.name }.count
            guard count > 0 else { return nil }
            let ips = addresses.map(\.description).joined(separator: ", ")
            return UnrecognizedTunnel(name: iface.name, evidence: "未识别的隧道 \(iface.name)（\(ips)，路由 \(count) 条）")
        }
    }
}
