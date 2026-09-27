import Foundation
import TunCanaryCore

/// DNS 规则：fake-ip 绕过、断开后的三种规则、连接期规则、TUN 关闭时的残留提示。全部使用合成数据。
enum DNSRuleTests {
    static let realAnswer = IPv4("192.0.2.80")!
    static let fakeAnswer = IPv4("198.18.0.26")!

    static let clash = ClashConfig(vergeTunModeEnabled: true, tunEnabled: true, tunDevice: "utun1024",
                                   dnsListenPort: 1053, dnsEnhancedMode: "fake-ip",
                                   fakeIPRange: IPv4CIDR("198.18.0.1/16")!)

    /// 没有 VPN、TUN 运行、系统解析返回 fake-ip。
    static func snapshot(saved: [String], canary: [IPv4] = [fakeAnswer], tunOn: Bool = true) -> LocalSnapshot {
        var config = clash
        config.tunEnabled = tunOn
        var snapshot = VPNTests.baseSnapshot()
        snapshot.clashConfig = .collected(config)
        snapshot.mihomoRunning = .collected(true)
        snapshot.primaryService = .collected(PrimaryServiceInfo(
            serviceID: "S1", name: "Wi-Fi", interfaceName: "en0", savedDNS: saved, stateDNS: ["192.168.1.1"]))
        snapshot.mihomoDNS = tunOn ? .success(port: 1053, latency: 0.01, answers: [fakeAnswer]) : .notApplicable
        snapshot.canary = .resolved(canary)
        return snapshot
    }

    /// Example VPN 已连接，主网络与代理状态同 `snapshot`。
    static func connected(saved: [String], canary: [IPv4] = [fakeAnswer], tunOn: Bool = true) -> LocalSnapshot {
        var connected = VPNTests.exampleConnected()
        let base = snapshot(saved: saved, canary: canary, tunOn: tunOn)
        connected.clashConfig = base.clashConfig
        connected.mihomoRunning = base.mihomoRunning
        connected.primaryService = base.primaryService
        connected.mihomoDNS = base.mihomoDNS
        connected.canary = base.canary
        return connected
    }

    static func evaluate(_ snapshot: LocalSnapshot, _ settings: AppSettings = AppSettings(),
                         adapters: [VPNAdapterConfig] = []) -> LocalAssessment {
        LocalEvaluator(paths: VPNTests.paths, adapters: adapters)
            .evaluate(snapshot: snapshot, settings: settings, inGracePeriod: false)
    }

    static var suite: TestSuite {
        TestSuite("Core.DNSRules", [
            TestCase("默认不检查：系统解析返回 fake-ip → 绿，可采用当前值") { t in
                let result = evaluate(snapshot(saved: ["192.0.2.53"]))
                let dns = try t.require(result.card(.primaryDNS))
                t.expectEqual(dns.severity, .ok)
                t.expectEqual(dns.conclusion, "系统解析返回 fake-ip，DNS 经过代理")
                t.expectEqual(result.learnableExpectedDNS, ["192.0.2.53"])
                t.expectEqual(result.severity, .ok)
            },
            TestCase("默认不检查：系统解析返回真实地址 → 红 dns.bypassProxy") { t in
                let result = evaluate(snapshot(saved: [], canary: [realAnswer]))
                let dns = try t.require(result.card(.primaryDNS))
                t.expectEqual(dns.severity, .critical)
                t.expectEqual(dns.conclusion, "系统 DNS 未经过代理")
                t.expectEqual(dns.faultKey, .dnsBypassProxy)
                t.expect(dns.evidence.contains("系统解析 www.google.com 返回真实地址 192.0.2.80"), "\(dns.evidence)")
                t.expectNil(result.learnableExpectedDNS, "绕过时不能把当前值当成预期")
            },
            TestCase("默认不检查：探针未测时为绿") { t in
                var snap = snapshot(saved: [])
                snap.canary = .notTested
                t.expectEqual(evaluate(snap).card(.primaryDNS)?.conclusion, "未设置 DNS 规则")
                t.expectNil(evaluate(snap).learnableExpectedDNS)
            },
            TestCase("指定地址：一致为绿，不一致为红，一致但绕过也为红") { t in
                let settings = AppSettings(expectedDNS: ["192.0.2.53"])
                t.expectEqual(evaluate(snapshot(saved: ["192.0.2.53"]), settings).severity, .ok)
                let mismatch = evaluate(snapshot(saved: []), settings)
                t.expectEqual(mismatch.faultKeys, [.dnsNotRestored])
                t.expectEqual(mismatch.card(.primaryDNS)?.conclusion, "VPN 已断开、TUN 运行中，DNS 未恢复为 192.0.2.53")
                let bypass = evaluate(snapshot(saved: ["192.0.2.53"], canary: [realAnswer]), settings)
                t.expectEqual(bypass.faultKeys, [.dnsBypassProxy])
            },
            TestCase("为空：保存值为空为绿，否则为红") { t in
                let settings = AppSettings(disconnectedDNSRule: .empty)
                t.expectEqual(evaluate(snapshot(saved: []), settings).card(.primaryDNS)?.conclusion, "DNS 为空，符合预期")
                let result = evaluate(snapshot(saved: ["192.0.2.53"]), settings)
                t.expectEqual(result.faultKeys, [.dnsNotRestored])
                t.expectEqual(result.card(.primaryDNS)?.conclusion, "VPN 已断开、TUN 运行中，DNS 未恢复（应为空）")
                t.expect(result.card(.primaryDNS)!.evidence.contains("保存值：192.0.2.53（应为空）"))
            },
            TestCase("TUN 关闭：只在“指定地址”且开启残留提示时判黄") { t in
                let tunOff = snapshot(saved: ["192.0.2.53"], tunOn: false)
                t.expectEqual(evaluate(tunOff).severity, .ok)
                let settings = AppSettings(expectedDNS: ["192.0.2.53"])
                t.expectEqual(evaluate(tunOff, settings).faultKeys, [.dnsResidual])
                var quiet = settings
                quiet.residualDNSWarning = false
                t.expectEqual(evaluate(tunOff, quiet).faultKeys, [])
            },
            TestCase("VPN 连接时：不检查或按 VPN 下发的 DNS") { t in
                var connected = VPNTests.exampleConnected()
                let base = snapshot(saved: ["192.0.2.53"])
                connected.clashConfig = base.clashConfig
                connected.mihomoRunning = base.mihomoRunning
                connected.primaryService = base.primaryService
                connected.mihomoDNS = base.mihomoDNS
                connected.canary = .resolved([realAnswer])
                let strict = evaluate(connected, adapters: [VPNTests.example])
                t.expectEqual(strict.faultKeys, [.dnsVPNMissing], "连接期不做绕过检测")
                let relaxed = evaluate(connected, AppSettings(connectedDNSRule: .notSet), adapters: [VPNTests.example])
                t.expectEqual(relaxed.card(.primaryDNS)?.conclusion, "VPN 已连接（不检查 DNS）")
                t.expectEqual(relaxed.faultKeys, [])
            },
            TestCase("由代理接管：连接期按断开期规则检查，内网站点照常探测") { t in
                let settings = AppSettings(expectedDNS: ["192.0.2.53"], connectedDNSRule: .proxyTakeover)
                let ok = evaluate(connected(saved: ["192.0.2.53"]), settings, adapters: [VPNTests.example])
                let dns = try t.require(ok.card(.primaryDNS))
                t.expectEqual(ok.vpnState, .connected)
                t.expectEqual(dns.severity, .ok)
                t.expectEqual(dns.conclusion, "VPN 已连接，由代理接管：DNS 为 192.0.2.53，符合预期")
                t.expectEqual(dns.hint, "连接期由代理接管；启用内网站点探测，内网站点失败时先检查代理能否解析内网域名")
                t.expect(ok.intranetProbeEnabled)
                t.expectNil(ok.learnableExpectedDNS, "连接期的保存值不能作为断开后的预期")
                t.expect(dns.evidence.contains("系统解析 www.google.com 返回 fake-ip 198.18.0.26"), "\(dns.evidence)")
            },
            TestCase("由代理接管：保存值被 VPN 改写 → 红 dns.notTakenOver") { t in
                let settings = AppSettings(expectedDNS: ["192.0.2.53"], connectedDNSRule: .proxyTakeover)
                let leak = evaluate(connected(saved: ["10.9.0.53"], canary: [realAnswer]), settings,
                                    adapters: [VPNTests.example])
                let dns = try t.require(leak.card(.primaryDNS))
                t.expectEqual(dns.severity, .critical)
                t.expectEqual(leak.faultKeys, [.dnsNotTakenOver])
                t.expectEqual(dns.conclusion, "VPN 已连接、TUN 运行中，DNS 未由代理接管为 192.0.2.53")
                t.expectEqual(dns.hint, "连接期 DNS 查询绕过了代理。把网络服务的 DNS 改为 192.0.2.53；VPN 客户端可能会再次改写")
                t.expectEqual(dns.evidence.first, "保存值：10.9.0.53（VPN 下发的 DNS）")
                t.expect(dns.evidence.contains("系统解析 www.google.com 返回真实地址 192.0.2.80"), "\(dns.evidence)")
                t.expect(leak.intranetProbeEnabled)

                let empty = AppSettings(disconnectedDNSRule: .empty, connectedDNSRule: .proxyTakeover)
                let emptyLeak = evaluate(connected(saved: ["10.9.0.53"]), empty, adapters: [VPNTests.example])
                t.expectEqual(emptyLeak.card(.primaryDNS)?.conclusion, "VPN 已连接、TUN 运行中，DNS 未由代理接管（应为空）")
                t.expectEqual(emptyLeak.card(.primaryDNS)?.hint,
                              "连接期 DNS 查询绕过了代理。清空网络服务保存的 DNS；VPN 客户端可能会再次改写")
            },
            TestCase("由代理接管：保存值符合但系统解析返回真实地址 → 红 dns.bypassProxy") { t in
                let settings = AppSettings(expectedDNS: ["192.0.2.53"], connectedDNSRule: .proxyTakeover)
                let result = evaluate(connected(saved: ["192.0.2.53"], canary: [realAnswer]), settings,
                                      adapters: [VPNTests.example])
                t.expectEqual(result.faultKeys, [.dnsBypassProxy])
                let notSet = AppSettings(connectedDNSRule: .proxyTakeover)
                let fake = evaluate(connected(saved: ["10.9.0.53"]), notSet, adapters: [VPNTests.example])
                t.expectEqual(fake.card(.primaryDNS)?.conclusion, "VPN 已连接，由代理接管：系统解析返回 fake-ip，DNS 经过代理")
                t.expectEqual(evaluate(connected(saved: ["10.9.0.53"], canary: [realAnswer]), notSet,
                                       adapters: [VPNTests.example]).faultKeys, [.dnsBypassProxy])
            },
            TestCase("由代理接管：TUN 关闭时不检查，也不提示残留") { t in
                let settings = AppSettings(expectedDNS: ["192.0.2.53"], connectedDNSRule: .proxyTakeover)
                let result = evaluate(connected(saved: ["192.0.2.53"], tunOn: false), settings, adapters: [VPNTests.example])
                t.expectEqual(result.card(.primaryDNS)?.conclusion, "VPN 已连接、TUN 已关闭，不检查 DNS")
                t.expectEqual(result.faultKeys, [])
            },
            TestCase("恢复步骤：未指定地址时不写具体 DNS") { t in
                let generic = RecoveryGuide.steps(serviceName: "Wi-Fi")
                t.expectEqual(generic.count, 5)
                t.expect(generic[2].hasSuffix("核对 DNS 是否为你期望的值。"), generic[2])
                let specific = RecoveryGuide.steps(serviceName: "USB LAN", expectedDNS: ["192.0.2.53"])
                t.expectEqual(specific[2], "运行 networksetup -getdnsservers \"USB LAN\"，核对 DNS 是否恢复为预期值（192.0.2.53）。")
            },
        ])
    }
}
