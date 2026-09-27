import Foundation
import TunCanaryCore

/// 检查 MagicDNS：向 `100.100.100.100` 反查本机的 Tailscale 地址，得到本机的 MagicDNS 名称，
/// 再用系统解析器正向解析这个名称。不依赖 `tailscale` 命令行。
public struct MagicDNSProber: Sendable {
    public static let server = "100.100.100.100"

    public var timeout: TimeInterval
    private let resolver: SystemResolverCanary

    /// - Parameters:
    ///   - timeout: 反查（UDP）超时，秒。
    ///   - resolveTimeout: 系统解析超时，秒。
    public init(timeout: TimeInterval = PulseConstants.mihomoDNSTimeout,
                resolveTimeout: TimeInterval = PulseConstants.commandTimeout) {
        self.timeout = timeout
        self.resolver = SystemResolverCanary(timeout: resolveTimeout)
    }

    /// 没有 Tailscale 隧道时返回 `.notCollected`。
    public func probe() async -> Collected<TailnetProbeSnapshot> {
        guard let interfaces = await Blocking.run({ try? InterfaceScanner().scan() }) else {
            return .failed(reason: "网络接口读取失败")
        }
        guard let tunnel = interfaces.first(where: {
                  $0.isTunnel && $0.isUp && $0.ipv4Addresses.contains(where: IPv4CIDR.tailscale.contains)
              }),
              let address = tunnel.ipv4Addresses.first(where: IPv4CIDR.tailscale.contains) else {
            return .notCollected
        }
        let timeout = self.timeout
        let reverse = await Blocking.run { Self.reverse(address, timeout: timeout) }
        guard case .answered(name: let name?) = reverse else {
            return .collected(TailnetProbeSnapshot(selfAddress: address, reverse: reverse))
        }
        let forward = await resolver.resolve(host: name)
        return .collected(TailnetProbeSnapshot(selfAddress: address, reverse: reverse, forward: forward))
    }

    /// 阻塞反查。NXDOMAIN 视为“有应答、没有名称”。
    public static func reverse(_ address: IPv4, timeout: TimeInterval) -> MagicDNSReverseResult {
        let outcome = UDPDNSClient.query(host: server, port: 53, name: DNSMessage.reverseName(address),
                                         type: DNSMessage.typePTR, timeout: timeout)
        return result(outcome)
    }

    /// 把查询结果映射为模型。
    public static func result(_ outcome: DNSQueryOutcome) -> MagicDNSReverseResult {
        switch outcome {
        case .answered(_, let response):
            switch response.responseCode {
            case 0: return .answered(name: response.ptrAnswer)
            case 3: return .answered(name: nil)
            default: return .failed(reason: "应答码 \(response.responseCode)")
            }
        case .timedOut:
            return .timedOut
        case .refused:
            return .failed(reason: "端口拒绝")
        case .failed(let reason):
            return .failed(reason: reason)
        }
    }
}
