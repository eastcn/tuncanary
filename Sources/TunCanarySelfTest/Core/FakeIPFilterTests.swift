import Foundation
import TunCanaryCore

/// fake-ip 过滤名单：解析、通配匹配、对绕过判定的影响，以及探针域名设置。
enum FakeIPFilterTests {
    static var suite: TestSuite {
        TestSuite("Core.FakeIPFilter", [
            TestCase("解析块列表（与子键同缩进或更深）和行内列表") { t in
                let block = """
                dns:
                  enable: true
                  fake-ip-filter:
                  - '*.lan'
                  - "+.example.com" # 注释
                  - localhost.ptlogin2.qq.com
                  fake-ip-filter-mode: blacklist
                tun:
                  enable: true
                """
                t.expectEqual(ClashConfigParser.scanList(block, top: "dns", key: "fake-ip-filter"),
                              ["*.lan", "+.example.com", "localhost.ptlogin2.qq.com"])
                let deeper = "dns:\n  fake-ip-filter:\n    - a.test\n    - b.test\n  listen: :1053\n"
                t.expectEqual(ClashConfigParser.scanList(deeper, top: "dns", key: "fake-ip-filter"), ["a.test", "b.test"])
                let inline = "dns:\n  fake-ip-filter: ['+.lan', geosite:private]\n"
                t.expectEqual(ClashConfigParser.scanList(inline, top: "dns", key: "fake-ip-filter"), ["+.lan", "geosite:private"])
                t.expectNil(ClashConfigParser.scanList("dns:\n  listen: :53\n", top: "dns", key: "fake-ip-filter"))
                let config = ClashConfigParser.parse(vergeYAML: nil, clashVergeYAML: block)
                t.expectEqual(config.fakeIPFilterMode, "blacklist")
                t.expectEqual(config.fakeIPFilter?.count, 3)
            },
            TestCase("通配规则") { t in
                t.expect(FakeIPFilter.matches(host: "www.google.com", pattern: "www.google.com"))
                t.expect(FakeIPFilter.matches(host: "www.google.com", pattern: "*.google.com"))
                t.expect(!FakeIPFilter.matches(host: "a.b.google.com", pattern: "*.google.com"))
                t.expect(FakeIPFilter.matches(host: "google.com", pattern: "+.google.com"))
                t.expect(FakeIPFilter.matches(host: "a.b.google.com", pattern: "+.google.com"))
                t.expect(!FakeIPFilter.matches(host: "google.com", pattern: ".google.com"))
                t.expect(FakeIPFilter.matches(host: "a.b.google.com", pattern: ".google.com"))
                t.expect(FakeIPFilter.matches(host: "stun.l.google.com", pattern: "stun.*.*.com"))
                t.expect(!FakeIPFilter.matches(host: "notgoogle.com", pattern: "+.google.com"))
                t.expect(FakeIPFilter.matches(host: "WWW.Google.COM.", pattern: "www.google.com"))
            },
            TestCase("黑名单、白名单与外部列表") { t in
                let host = "www.google.com"
                t.expectEqual(FakeIPFilter.evaluate(host: host, filter: nil, mode: nil), .fakeIP)
                t.expectEqual(FakeIPFilter.evaluate(host: host, filter: ["*.lan"], mode: nil), .fakeIP)
                t.expectEqual(FakeIPFilter.evaluate(host: host, filter: ["+.google.com"], mode: "blacklist"),
                              .excluded(pattern: "+.google.com"))
                t.expectEqual(FakeIPFilter.evaluate(host: host, filter: ["+.google.com"], mode: "whitelist"), .fakeIP)
                t.expectEqual(FakeIPFilter.evaluate(host: host, filter: ["+.github.com"], mode: "whitelist"), .excluded(pattern: nil))
                t.expectEqual(FakeIPFilter.evaluate(host: host, filter: ["*.lan", "geosite:cn"], mode: nil),
                              .uncertain(entries: ["geosite:cn"]))
            },
            TestCase("探针域名被排除或无法确认时，不判绕过") { t in
                var snapshot = DNSRuleTests.snapshot(saved: [], canary: [DNSRuleTests.realAnswer])
                var config = DNSRuleTests.clash
                config.fakeIPFilter = ["+.google.com"]
                snapshot.clashConfig = .collected(config)
                let excluded = DNSRuleTests.evaluate(snapshot)
                t.expectEqual(excluded.faultKeys, [])
                t.expect(excluded.card(.primaryDNS)!.evidence.contains(
                    "探针域名 www.google.com 不分配 fake-ip（匹配 +.google.com），无法检测绕过，请在设置中更换探针域名"),
                    "\(excluded.card(.primaryDNS)!.evidence)")

                config.fakeIPFilter = ["geosite:private"]
                snapshot.clashConfig = .collected(config)
                let uncertain = DNSRuleTests.evaluate(snapshot)
                t.expectEqual(uncertain.faultKeys, [])
                t.expect(uncertain.card(.primaryDNS)!.evidence.contains { $0.contains("无法确认是否绕过") })

                // 换一个不在名单里的探针域名，绕过照常判红。
                config.fakeIPFilter = ["+.google.com"]
                snapshot.clashConfig = .collected(config)
                snapshot.canaryHost = "github.com"
                t.expectEqual(DNSRuleTests.evaluate(snapshot).faultKeys, [.dnsBypassProxy])
            },
            TestCase("探针域名：校验、保存与读取") { t in
                t.expect(SettingsValidator.isValidHostName("www.google.com"))
                t.expect(SettingsValidator.isValidHostName("a-b.example"))
                for bad in ["localhost", "8.8.8.8", "-a.com", "a..com", "a b.com", "", String(repeating: "a", count: 64) + ".com"] {
                    t.expect(!SettingsValidator.isValidHostName(bad), bad)
                }
                t.expectEqual(SettingsValidator.validate(AppSettings(canaryHost: "localhost")), [.canaryHostInvalid("localhost")])
                t.expectEqual(AppSettings(canaryHost: "github.com").proxySource.canaryHost, "github.com")

                let suite = "np-test-canary-\(UUID().uuidString)"
                let defaults = try t.require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let store = SettingsStore(defaults: defaults)
                t.expectEqual(store.load().canaryHost, "www.google.com")
                store.save(AppSettings(canaryHost: "github.com"))
                t.expectEqual(store.load().canaryHost, "github.com")
                defaults.set("not a host", forKey: SettingsStore.Key.canaryHost)
                t.expectEqual(store.load().canaryHost, "www.google.com")
            },
            TestCase("检测页与出口目标：校验、保存与读取") { t in
                let page = CheckPage(name: "出口检测", url: URL(string: "https://check.example.test/")!)
                t.expectEqual(AppSettings().checkPages, [])
                t.expectEqual(AppSettings().effectiveEgressTargets, [.cloudflare])
                t.expectEqual(AppSettings(egressTargets: [.claude, .cloudflare, .claude]).effectiveEgressTargets, [.cloudflare, .claude])
                t.expectEqual(AppSettings(egressTargets: []).effectiveEgressTargets, [.cloudflare])
                let bad = CheckPage(name: "", url: URL(string: "ftp://x.test/")!)
                t.expectEqual(SettingsValidator.validate(AppSettings(checkPages: [page, bad])), [.checkPageInvalid(1)])
                t.expectEqual(SettingsValidator.validate(AppSettings(checkPages: [page, page, page, page])), [.tooManyCheckPages])

                let suite = "np-test-pages-\(UUID().uuidString)"
                let defaults = try t.require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let store = SettingsStore(defaults: defaults)
                let saved = AppSettings(checkPages: [page], egressTargets: [.claude, .cloudflare])
                store.save(saved)
                t.expectEqual(store.load().checkPages, [page])
                t.expectEqual(store.load().egressTargets, [.cloudflare, .claude])
                defaults.set(["unknown"], forKey: SettingsStore.Key.egressTargets)
                t.expectEqual(store.load().egressTargets, [.cloudflare])
            },
            TestCase("自定义出口目标：解析、顺序去重、上限与读写") { t in
                let custom = try t.require(EgressIPTarget.custom("Trace.Example.test"))
                t.expectEqual(custom.rawValue, "trace.example.test")
                t.expectEqual(custom.host, "trace.example.test")
                t.expectEqual(custom.url.absoluteString, "https://trace.example.test/cdn-cgi/trace")
                t.expect(!custom.isBuiltIn)
                t.expectEqual(EgressIPTarget.custom(" https://trace.example.test/some/path?q=1 "), custom, "网址只取主机名")
                t.expectEqual(EgressIPTarget.custom("trace.example.test/path"), custom)
                t.expectNil(EgressIPTarget.custom("https://user:pw@trace.example.test/"), "不接受含账号的网址")
                t.expectNil(EgressIPTarget.custom("192.0.2.1"), "IP 字面量没有 trace")
                t.expectNil(EgressIPTarget.custom("not a host"))
                t.expectNil(EgressIPTarget.custom("cloudflare"), "不能与内置项的原始值冲突")
                t.expectEqual(EgressIPTarget(rawValue: "claude"), .claude, "旧版保存的值仍可读取")
                t.expectEqual(EgressIPTarget.claude.url.absoluteString, "https://claude.ai/cdn-cgi/trace")

                let other = try t.require(EgressIPTarget.custom("edge.example.test"))
                let sameAsBuiltIn = try t.require(EgressIPTarget.custom("claude.ai"))
                let settings = AppSettings(egressTargets: [other, .cloudflare, custom, other, sameAsBuiltIn, .claude])
                t.expectEqual(settings.effectiveEgressTargets, [.cloudflare, .claude, other, custom],
                              "内置项在前，自定义项按用户顺序，按域名去重")
                t.expectEqual(AppSettings(egressTargets: [custom]).effectiveEgressTargets, [.cloudflare, custom],
                              "没有内置项时补上 Cloudflare")
                let many = (1...7).compactMap { EgressIPTarget.custom("h\($0).example.test") }
                t.expectEqual(AppSettings(egressTargets: many).effectiveEgressTargets.count, 1 + EgressIPTarget.maxCustom)
                t.expectEqual(SettingsValidator.validate(AppSettings(egressTargets: many)), [.tooManyEgressTargets])

                let suite = "np-test-egress-\(UUID().uuidString)"
                let defaults = try t.require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let store = SettingsStore(defaults: defaults)
                store.save(AppSettings(egressTargets: [.cloudflare, custom]))
                t.expectEqual(defaults.stringArray(forKey: SettingsStore.Key.egressTargets),
                              ["cloudflare", "trace.example.test"])
                t.expectEqual(store.load().effectiveEgressTargets, [.cloudflare, custom])
                defaults.set(["claude", "bad host", "trace.example.test"], forKey: SettingsStore.Key.egressTargets)
                t.expectEqual(store.load().egressTargets, [.claude, custom], "跳过无效项")

                // 内置 ChatGPT 与淘宝：固定地址；与内置项同域名的自定义项视为打开该内置项。
                t.expectEqual(EgressIPTarget.chatgpt.url.absoluteString, "https://chatgpt.com/cdn-cgi/trace")
                t.expectEqual(EgressIPTarget.taobao.format, .taobaoIPInfo)
                t.expectEqual(EgressIPTarget.taobao.url.host, "ip.taobao.com")
                t.expectEqual(EgressIPTarget(rawValue: "taobao"), .taobao)
                let chatgptHost = try t.require(EgressIPTarget.custom("chatgpt.com"))
                t.expectEqual(chatgptHost.matchingBuiltIn, .chatgpt)
                t.expectEqual(AppSettings(egressTargets: [.cloudflare, chatgptHost, custom]).effectiveEgressTargets,
                              [.cloudflare, .chatgpt, custom])
                t.expectEqual(SettingsValidator.validate(AppSettings(egressTargets: [chatgptHost] + many.prefix(5))), [],
                              "与内置项同域名的不计入自定义上限")

                let json = try JSONEncoder().encode(AppSettings(egressTargets: [.cloudflare, custom]))
                t.expectEqual(try JSONDecoder().decode(AppSettings.self, from: json).egressTargets, [.cloudflare, custom])
            },
        ])
    }
}
