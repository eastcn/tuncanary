import Foundation

/// 守护进程的一次采样：TUN、VPN、主网络服务和代理参数。
public struct DNSGuardSample: Sendable, Equatable {
    public enum Tun: Sendable, Equatable {
        case running(interface: String)
        /// 未运行或无法确认，带原因。
        case notRunning(String)
    }

    public struct Service: Sendable, Equatable {
        public var serviceID: String
        /// 接口类型，例如 `IEEE80211`、`Ethernet`；取不到时为 nil。
        public var type: String?
        /// 保存的 DNS（`Setup:` 层），已规范化。
        public var savedDNS: [String]

        public init(serviceID: String, type: String?, savedDNS: [String]) {
            self.serviceID = serviceID
            self.type = type
            self.savedDNS = DNSList.normalize(savedDNS)
        }
    }

    public var tun: Tun
    public var vpn: VPNConnectionState
    /// 主网络服务；读取失败时为 `.failed`。
    public var service: Collected<Service>
    public var fakeIPRange: IPv4CIDR?
    /// 代理 DNS 在本机监听的端口。
    public var proxyDNSPort: Int?

    public init(tun: Tun, vpn: VPNConnectionState, service: Collected<Service>,
                fakeIPRange: IPv4CIDR? = nil, proxyDNSPort: Int? = nil) {
        self.tun = tun
        self.vpn = vpn
        self.service = service
        self.fakeIPRange = fakeIPRange
        self.proxyDNSPort = proxyDNSPort
    }

    /// 由菜单栏应用同一套采集与判定结果构造。TUN 与 VPN 状态沿用 `LocalEvaluator` 的规则。
    public static func make(snapshot: LocalSnapshot, assessment: LocalAssessment, serviceType: String?) -> DNSGuardSample {
        let tun: Tun
        if case .running(let name) = assessment.tunState {
            tun = .running(interface: name)
        } else {
            tun = .notRunning(assessment.card(.proxyTun)?.conclusion ?? "TUN 状态未知")
        }
        let config = snapshot.clashConfig.value
        return DNSGuardSample(
            tun: tun,
            vpn: assessment.vpnState,
            service: snapshot.primaryService.map {
                Service(serviceID: $0.serviceID, type: serviceType, savedDNS: $0.savedDNS)
            },
            fakeIPRange: config?.isFakeIPMode == true ? config?.fakeIPRange : nil,
            proxyDNSPort: config?.dnsListenPort)
    }
}

/// 阶段 B 的 VPN 探针：通过代理 DNS 查询 VPN 域名的 A 记录。
public enum DNSGuardProbeResult: Sendable, Equatable {
    case notRun
    case answered([IPv4])
    /// 超时或端口拒绝。
    case noResponse
    case failed(String)
}

/// 一次写入：服务、阶段、写入前应看到的保存值和目标值。
public struct DNSGuardWritePlan: Sendable, Equatable {
    public var serviceID: String
    public var phase: DNSGuardPhase
    public var currentDNS: [String]
    public var targetDNS: [String]

    public init(serviceID: String, phase: DNSGuardPhase, currentDNS: [String], targetDNS: [String]) {
        self.serviceID = serviceID
        self.phase = phase
        self.currentDNS = currentDNS
        self.targetDNS = targetDNS
    }
}

/// 判定结果。
public enum DNSGuardDecision: Sendable, Equatable {
    case skip(phase: DNSGuardPhase?, reason: String)
    /// 保存的 DNS 已等于目标值。
    case compliant(phase: DNSGuardPhase)
    /// 阶段 B 需要先查询 VPN 探针，再用结果重新判定。
    case needsProbe(host: String, port: Int)
    /// 连续失败后的退避期。
    case backoff(phase: DNSGuardPhase, until: Date)
    /// 连接期写入次数达到上限，停用连接期接管。
    case suspendTakeover
    case write(DNSGuardWritePlan)
}

/// 守护进程的判定（纯函数）。
public enum DNSGuardDecider {
    /// 连接期写入次数的统计窗口（秒）。
    public static let takeoverWindow: TimeInterval = 600

    /// 两次采样是否处在 VPN 切换过程中：VPN 状态不一致或未确认，或同一服务保存的 DNS 发生变化。
    public static func isTransition(_ first: DNSGuardSample, _ second: DNSGuardSample) -> Bool {
        if first.vpn != second.vpn || second.vpn == .unconfirmed || second.vpn == .switching { return true }
        if let a = first.service.value, let b = second.service.value, a.serviceID == b.serviceID,
           !DNSList.sameSet(a.savedDNS, b.savedDNS) {
            return true
        }
        return false
    }

    /// 两次采样都满足条件才写入。检查顺序：TUN、主网络服务、VPN、保存的 DNS、退避，阶段 B 再检查写入次数和 VPN 探针。
    public static func decide(first: DNSGuardSample, second: DNSGuardSample, config: DNSGuardConfig,
                              state: DNSGuardState, probe: DNSGuardProbeResult = .notRun,
                              now: Date) -> DNSGuardDecision {
        for sample in [first, second] {
            if case .notRunning(let reason) = sample.tun {
                return .skip(phase: nil, reason: "TUN 未运行（\(reason)）")
            }
        }

        let services: [DNSGuardSample.Service]
        switch (first.service, second.service) {
        case (.collected(let a), .collected(let b)):
            services = [a, b]
        case (.failed(let reason), _), (_, .failed(let reason)):
            return .skip(phase: nil, reason: "未能读取主网络服务（\(reason)）")
        default:
            return .skip(phase: nil, reason: "未能读取主网络服务")
        }
        let service = services[1]
        guard services[0].serviceID == service.serviceID else {
            return .skip(phase: nil, reason: "两次采样之间主网络服务发生变化")
        }
        guard let type = service.type, services[0].type == type else {
            return .skip(phase: nil, reason: "无法确认主网络服务的类型")
        }
        guard !DNSGuardConfig.forbiddenServiceTypes.contains(type), config.allowedServiceTypes.contains(type) else {
            return .skip(phase: nil, reason: "主网络服务的类型 \(type) 不在允许写入的范围内")
        }

        guard first.vpn == second.vpn else {
            return .skip(phase: nil, reason: "两次采样的 VPN 状态不一致")
        }
        let phase: DNSGuardPhase
        switch second.vpn {
        case .disconnected:
            phase = .disconnected
        case .connected:
            guard config.connectedTakeover.enabled else {
                return .skip(phase: .connected, reason: "VPN 已连接，未启用连接期接管")
            }
            phase = .connected
        case .switching:
            return .skip(phase: nil, reason: "VPN 正在切换")
        case .unconfirmed:
            return .skip(phase: nil, reason: "VPN 状态未确认")
        }

        guard DNSList.sameSet(services[0].savedDNS, service.savedDNS) else {
            return .skip(phase: phase, reason: "两次采样之间保存的 DNS 发生变化")
        }
        let target = config.effectiveTargetDNS
        if !service.savedDNS.isEmpty && DNSList.sameSet(service.savedDNS, target) {
            return .compliant(phase: phase)
        }
        if let until = state.backoffUntil, until > now {
            return .backoff(phase: phase, until: until)
        }

        if phase == .connected {
            if state.connectedTakeoverSuspended {
                return .skip(phase: phase, reason: "连接期接管已停用，等待 VPN 断开")
            }
            let recent = state.connectedWrites.filter { $0 <= now && now.timeIntervalSince($0) < takeoverWindow }
            if recent.count >= config.connectedTakeover.maxWritesPerTenMinutes {
                return .suspendTakeover
            }
            guard let port = second.proxyDNSPort else {
                return .skip(phase: phase, reason: "代理配置缺少 DNS 端口，无法检查 VPN 探针")
            }
            guard let range = second.fakeIPRange else {
                return .skip(phase: phase, reason: "代理不是 fake-ip 模式，无法检查 VPN 探针")
            }
            switch probe {
            case .notRun:
                return .needsProbe(host: config.connectedTakeover.intranetProbeHost, port: port)
            case .answered(let answers) where answers.isEmpty:
                return .skip(phase: phase, reason: "代理无法解析 VPN 探针（无记录）")
            case .answered(let answers) where answers.contains(where: range.contains):
                return .skip(phase: phase, reason: "代理无法解析 VPN 探针（返回 fake-ip）")
            case .answered:
                break
            case .noResponse:
                return .skip(phase: phase, reason: "代理无法解析 VPN 探针（超时或无响应）")
            case .failed(let reason):
                return .skip(phase: phase, reason: "代理无法解析 VPN 探针（\(reason)）")
            }
        }

        return .write(DNSGuardWritePlan(serviceID: service.serviceID, phase: phase,
                                        currentDNS: service.savedDNS, targetDNS: target))
    }
}
