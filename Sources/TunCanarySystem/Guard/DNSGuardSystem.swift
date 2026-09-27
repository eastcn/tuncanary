import Foundation
import SystemConfiguration
import TunCanaryCore

/// 用菜单栏应用的采集与判定得出守护进程的样本。不查询系统解析探针和代理 DNS，只看 TUN、VPN 和主网络服务。
public struct DNSGuardSystemSampler: DNSGuardSampling {
    public let paths: KnownPaths
    public let adapters: VPNAdapterSet

    public init(paths: KnownPaths, adapters: VPNAdapterSet) {
        self.paths = paths
        self.adapters = adapters
    }

    public func sample() async -> DNSGuardSample {
        let configuration = SystemSnapshotProvider.Configuration(
            paths: paths, adapters: adapters.adapters, resolvesCanary: false, probesMihomoDNS: false,
            dnsGuardPaths: nil)
        let snapshot = await SystemSnapshotProvider(configuration: configuration).collectSnapshot()
        let assessment = LocalEvaluator(paths: paths, adapterSet: adapters)
            .evaluate(snapshot: snapshot, settings: AppSettings(), inGracePeriod: false)
        let type = snapshot.primaryService.value.flatMap { DNSGuardPreferences.serviceType($0.serviceID) }
        return DNSGuardSample.make(snapshot: snapshot, assessment: assessment, serviceType: type)
    }
}

/// 通过 SCPreferences 读写服务的 DNS 设置。
public enum DNSGuardPreferences {
    static let name = "TunCanaryDNSGuard" as CFString

    /// 服务的接口类型，例如 `IEEE80211`、`Ethernet`。读不到时为 nil。普通用户也能读取。
    public static func serviceType(_ serviceID: String) -> String? {
        guard let prefs = SCPreferencesCreate(nil, name, nil),
              let service = SCNetworkServiceCopy(prefs, serviceID as CFString),
              let interface = SCNetworkServiceGetInterface(service),
              let type = SCNetworkInterfaceGetInterfaceType(interface) else { return nil }
        return type as String
    }

    /// 只替换 `ServerAddresses`，保留 DNS 设置中的其他键。
    public static func updatedConfiguration(_ configuration: [String: Any]?, target: [String]) -> [String: Any] {
        var result = configuration ?? [:]
        result[kSCPropNetDNSServerAddresses as String] = target
        return result
    }

    static func errorText() -> String {
        String(cString: SCErrorString(SCError()))
    }
}

/// 写入主网络服务保存的 DNS，并从 SCDynamicStore 读回。写入需要 root。
public struct DNSGuardSystemWriter: DNSGuardWriting {
    public init() {}

    public func write(_ plan: DNSGuardWritePlan) -> DNSGuardWriteOutcome {
        guard let prefs = SCPreferencesCreate(nil, DNSGuardPreferences.name, nil) else {
            return .failed("无法打开网络设置（\(DNSGuardPreferences.errorText())）")
        }
        guard SCPreferencesLock(prefs, true) else {
            return .failed("无法锁定网络设置（\(DNSGuardPreferences.errorText())）")
        }
        defer { SCPreferencesUnlock(prefs) }

        guard let service = SCNetworkServiceCopy(prefs, plan.serviceID as CFString) else {
            return .changed("写入前复读发现网络服务已不存在，放弃写入")
        }
        guard let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else {
            return .failed("网络服务没有 DNS 设置")
        }
        let current = SCNetworkProtocolGetConfiguration(dns) as? [String: Any]
        let saved = DynamicStoreMapping.serverAddresses(current)
        guard DNSList.sameSet(saved, plan.currentDNS) else {
            return .changed("写入前复读发现保存的 DNS 已变化，放弃写入")
        }
        let updated = DNSGuardPreferences.updatedConfiguration(current, target: plan.targetDNS)
        guard SCNetworkProtocolSetConfiguration(dns, updated as CFDictionary) else {
            return .failed("修改 DNS 设置失败（\(DNSGuardPreferences.errorText())）")
        }
        guard SCPreferencesCommitChanges(prefs) else {
            return .failed("保存网络设置失败（\(DNSGuardPreferences.errorText())）")
        }
        guard SCPreferencesApplyChanges(prefs) else {
            return .failed("应用网络设置失败（\(DNSGuardPreferences.errorText())）")
        }
        return .written
    }

    public func readBack(serviceID: String) -> DNSGuardReadBack {
        let result = DynamicStoreReader().read()
        let service = result.primaryService.value
        return DNSGuardReadBack(
            primaryServiceID: service?.serviceID,
            savedDNS: service?.serviceID == serviceID ? service?.savedDNS : nil,
            resolverDNS: result.globalDNS.value)
    }
}

/// 通过代理 DNS 查询 VPN 探针的 A 记录。
public struct DNSGuardSystemProber: DNSGuardProbing {
    public var host: String
    public var timeout: TimeInterval

    public init(host: String = PulseConstants.mihomoDNSHost, timeout: TimeInterval = PulseConstants.mihomoDNSTimeout) {
        self.host = host
        self.timeout = timeout
    }

    public func probe(host name: String, port: Int) async -> DNSGuardProbeResult {
        let server = host
        let timeout = timeout
        return await Blocking.run {
            switch UDPDNSClient.query(host: server, port: port, name: name, timeout: timeout) {
            case .answered(_, let response): return .answered(response.ipv4Answers)
            case .timedOut, .refused: return .noResponse
            case .failed(let reason): return .failed(reason)
            }
        }
    }
}
