import Foundation
import TunCanaryCore

/// 代理客户端：手动模式的 TUN 判定、卡片名称、恢复步骤与设置保存。全部使用合成数据。
enum ProxyClientTests {
    static let manual = ManualProxyConfig(fakeIPRange: "198.18.0.0/15", dnsPort: 1053, coreProcessName: "mihomo")
    static let settings = AppSettings(proxyClient: .manual, manualProxy: manual)

    static func snapshot(tunUp: Bool = true, coreRunning: Bool? = true) -> LocalSnapshot {
        var snapshot = DNSRuleTests.snapshot(saved: [])
        snapshot.clashConfig = .collected(ClashConfig.manual(manual))
        if !tunUp {
            snapshot.interfaces = .collected([VPNTests.overlay])
        }
        switch coreRunning {
        case .some(true):
            snapshot.processes = .collected([ProcessEntry(pid: 300, executablePath: "/opt/homebrew/bin/mihomo")])
        case .some(false):
            snapshot.processes = .collected([])
        case .none:
            snapshot.processes = .notCollected
        }
        return snapshot
    }

    static var suite: TestSuite {
        TestSuite("Core.ProxyClient", [
            TestCase("手动模式：接口与进程都在 → TUN 运行，卡片用通用名称") { t in
                let result = DNSRuleTests.evaluate(snapshot(), settings)
                let tun = try t.require(result.card(.proxyTun))
                t.expectEqual(result.tunState, .running(interface: "utun1024"))
                t.expectEqual(tun.title, "代理 TUN")
                t.expectEqual(tun.conclusion, "utun1024 存在")
                t.expectEqual(tun.evidence, [
                    "手动模式：fake-ip 网段 198.18.0.0/15",
                    "utun1024 存在（198.18.0.1，位于 fake-ip 网段 198.18.0.0/15）",
                    "mihomo 运行中",
                ])
                t.expectEqual(result.card(.proxyDNS)?.title, "代理 DNS")
                t.expectEqual(result.severity, .ok)
            },
            TestCase("手动模式：没有接口 → 关闭；进程未运行 → 未生效；进程未采集 → 未确认") { t in
                let off = DNSRuleTests.evaluate(snapshot(tunUp: false), settings)
                t.expectEqual(off.tunState, .off)
                t.expectEqual(off.card(.proxyTun)?.conclusion, "未发现 TUN 接口")
                let inactive = DNSRuleTests.evaluate(snapshot(coreRunning: false), settings)
                t.expectEqual(inactive.tunState, .inactive)
                t.expectEqual(inactive.faultKeys, [.tunInactive])
                t.expectEqual(inactive.card(.proxyTun)?.conclusion, "发现 TUN 接口，但 mihomo 未运行")
                t.expectEqual(DNSRuleTests.evaluate(snapshot(coreRunning: nil), settings).tunState, .unknown)
            },
            TestCase("手动模式：不填进程名时只看接口；不填端口时不检测代理 DNS") { t in
                var bare = settings
                bare.manualProxy = ManualProxyConfig()
                var snap = snapshot(coreRunning: nil)
                snap.clashConfig = .collected(ClashConfig.manual(bare.manualProxy))
                snap.mihomoDNS = .notApplicable
                let result = DNSRuleTests.evaluate(snap, bare)
                t.expect(result.tunState.isRunning)
                t.expectEqual(result.card(.proxyDNS)?.severity, .ok)
                t.expectEqual(result.card(.proxyDNS)?.conclusion, "未填写端口，不检测")
            },
            TestCase("手动模式：绕过提示与恢复步骤用通用名称") { t in
                var snap = snapshot()
                snap.canary = .resolved([DNSRuleTests.realAnswer])
                let dns = try t.require(DNSRuleTests.evaluate(snap, settings).card(.primaryDNS))
                t.expectEqual(dns.hint, "系统解析返回真实地址，DNS 查询绕过了代理。关闭并重新开启代理 TUN，再核对网络服务的 DNS 设置")
                t.expectEqual(RecoveryGuide.steps(serviceName: "Wi-Fi", proxy: settings.proxySource)[1],
                              "在代理客户端中关闭 TUN，等待数秒后重新开启。")
                t.expectEqual(RecoveryGuide.steps(serviceName: "Wi-Fi")[1], "在 Clash Verge 中关闭 TUN，等待数秒后重新开启。")
            },
            TestCase("手动参数校验") { t in
                t.expectEqual(SettingsValidator.validateManualProxy(manual), [])
                t.expectEqual(SettingsValidator.validateManualProxy(
                    ManualProxyConfig(fakeIPRange: "198.18/15", dnsPort: 70000, coreProcessName: "bin/mihomo")),
                    [.manualFakeIPRangeInvalid("198.18/15"), .manualDNSPortInvalid, .manualProcessNameInvalid])
                // 只在手动模式下参与整份校验。
                var clash = AppSettings()
                clash.manualProxy = ManualProxyConfig(fakeIPRange: "bad")
                t.expectEqual(SettingsValidator.validate(clash), [])
                clash.proxyClient = .manual
                t.expectEqual(SettingsValidator.validate(clash), [.manualFakeIPRangeInvalid("bad")])
            },
            TestCase("保存与读取；手动参数丢失时回到 Clash Verge Rev") { t in
                let suite = "np-test-proxy-\(UUID().uuidString)"
                let defaults = try t.require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let store = SettingsStore(defaults: defaults)
                t.expectEqual(store.load().proxyClient, .clashVergeRev)
                store.save(settings)
                let loaded = store.load()
                t.expectEqual(loaded.proxyClient, .manual)
                t.expectEqual(loaded.manualProxy, manual)
                defaults.set(Data("{}".utf8), forKey: SettingsStore.Key.manualProxy)
                t.expectEqual(store.load().proxyClient, .clashVergeRev)
                t.expectEqual(store.load().manualProxy, ManualProxyConfig())
            },
        ])
    }
}
