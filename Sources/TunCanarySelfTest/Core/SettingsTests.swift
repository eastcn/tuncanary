import Foundation
import TunCanaryCore

enum SettingsTests {
    /// 创建临时的 defaults 域。suite 名用绝对路径时，CFPreferences 把 plist 写在该路径，
    /// 不会在 ~/Library/Preferences 中留下文件。返回 suite 名与需要清理的临时目录。
    static func makeTemporaryDefaultsSuite() throws -> (suite: String, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuncanary-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appendingPathComponent("settings").path, directory)
    }

    /// 清理临时 defaults 域及其目录。
    static func removeTemporaryDefaultsSuite(_ suite: String, directory: URL) {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        CFPreferencesAppSynchronize(suite as CFString)
        try? FileManager.default.removeItem(at: directory)
    }

    static var suite: TestSuite {
        TestSuite("Core.Settings", [
            TestCase("默认值") { t in
                let settings = AppSettings()
                t.expectNil(settings.intranetURL)
                t.expectEqual(settings.expectedDNS, [])
                t.expectEqual(settings.disconnectedDNSRule, .notSet)
                t.expectEqual(settings.connectedDNSRule, .vpnProvided)
                t.expect(settings.residualDNSWarning)
                t.expect(settings.notificationsEnabled)
                t.expectEqual(settings.localCheckInterval, 20)
                t.expectEqual(settings.lightProbeInterval, 120)
                t.expectEqual(settings.sites, SiteCatalog.defaultSites)
                t.expect(!settings.isIntranetConfigured)
                t.expectEqual(AppSettings.default, settings)
            },
            TestCase("内网站点 URL 校验") { t in
                func url(_ text: String) -> Result<URL?, SettingsValidationError> { SettingsValidator.validateIntranetURL(text) }
                t.expectEqual(try url("").get(), nil)
                t.expectEqual(try url("  ").get(), nil)
                t.expectEqual(try url("https://intranet.corp.example/health").get()?.host, "intranet.corp.example")
                t.expectEqual(try url(" http://10.0.0.1:8080/ ").get()?.port, 8080)
                t.expectEqual(url("ftp://intranet.corp.example/"), .failure(.intranetURLScheme))
                t.expectEqual(url("intranet.corp.example"), .failure(.intranetURLScheme))
                t.expectEqual(url("https://"), .failure(.intranetURLMissingHost))
                t.expectEqual(url("http:///path"), .failure(.intranetURLMissingHost))
                t.expectEqual(url("http://bad host/"), .failure(.intranetURLInvalid))
            },
            TestCase("预期 DNS 必须是 IPv4") { t in
                t.expectEqual(try SettingsValidator.validateExpectedDNS("119.29.29.29, 223.5.5.5").get(), ["119.29.29.29", "223.5.5.5"])
                t.expectEqual(try SettingsValidator.validateExpectedDNS("119.29.29.29，223.5.5.5").get().count, 2)
                t.expectEqual(try SettingsValidator.validateExpectedDNS("8.8.8.8 1.1.1.1").get().count, 2)
                t.expectEqual(SettingsValidator.validateExpectedDNS(""), .failure(.expectedDNSEmpty))
                t.expectEqual(SettingsValidator.validateExpectedDNS([""]), .failure(.expectedDNSEmpty))
                t.expectEqual(SettingsValidator.validateExpectedDNS("119.29.29"), .failure(.expectedDNSInvalid("119.29.29")))
                t.expectEqual(SettingsValidator.validateExpectedDNS("dns.example"), .failure(.expectedDNSInvalid("dns.example")))
            },
            TestCase("整份校验与中文错误信息") { t in
                var settings = AppSettings()
                t.expectEqual(SettingsValidator.validate(settings), [])
                settings.expectedDNS = ["x"]
                settings.intranetURL = URL(string: "ftp://intranet.corp.example")
                let errors = SettingsValidator.validate(settings)
                t.expectEqual(errors, [.intranetURLScheme, .expectedDNSInvalid("x")])
                t.expectEqual(SettingsValidationError.intranetURLScheme.message, "内网站点 URL 必须是 http 或 https")
                t.expectEqual(SettingsValidationError.intranetURLMissingHost.message, "内网站点 URL 缺少主机名")
                t.expectEqual(SettingsValidationError.expectedDNSEmpty.message, "预期 DNS 至少填写一个 IPv4 地址")
            },
            TestCase("有效预期 DNS 与规则推断") { t in
                let blank = AppSettings(expectedDNS: [" ", ""])
                t.expectEqual(blank.effectiveExpectedDNS, [])
                t.expectEqual(blank.disconnectedDNSRule, .notSet)
                let listed = AppSettings(expectedDNS: ["223.5.5.5"])
                t.expectEqual(listed.disconnectedDNSRule, .equals)
                t.expectEqual(AppSettings(disconnectedDNSRule: .empty, expectedDNS: ["223.5.5.5"]).disconnectedDNSRule, .empty)
                // “指定地址”必须填写；其他规则可以留空。
                t.expectEqual(SettingsValidator.validate(AppSettings(disconnectedDNSRule: .equals)), [.expectedDNSEmpty])
                t.expectEqual(SettingsValidator.validate(AppSettings(disconnectedDNSRule: .empty)), [])
            },
            TestCase("DNS 规则：旧设置迁移与保存") { t in
                let suite = "np-test-dns-rules-\(UUID().uuidString)"
                let defaults = try t.require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let store = SettingsStore(defaults: defaults)
                // 全新安装：不检查。
                t.expectEqual(store.load().disconnectedDNSRule, .notSet)
                // 旧版只有 expectedDNS：迁移为“指定地址”。
                defaults.set(["119.29.29.29"], forKey: SettingsStore.Key.expectedDNS)
                let migrated = store.load()
                t.expectEqual(migrated.disconnectedDNSRule, .equals)
                t.expectEqual(migrated.expectedDNS, ["119.29.29.29"])
                // 保存后规则以键为准。
                var changed = migrated
                changed.disconnectedDNSRule = .empty
                changed.connectedDNSRule = .notSet
                changed.residualDNSWarning = false
                store.save(changed)
                t.expectEqual(store.load(), changed)
                changed.connectedDNSRule = .proxyTakeover
                store.save(changed)
                t.expectEqual(defaults.string(forKey: SettingsStore.Key.connectedDNSRule), "proxyTakeover")
                t.expectEqual(store.load().connectedDNSRule, .proxyTakeover)
                // 规则为“指定地址”但列表丢失时回落到不检查。
                defaults.removeObject(forKey: SettingsStore.Key.expectedDNS)
                defaults.set("equals", forKey: SettingsStore.Key.disconnectedDNSRule)
                t.expectEqual(store.load().disconnectedDNSRule, .notSet)
            },
            TestCase("旧 JSON 设置与站点可解码，新配置缺失时采用默认值") { t in
                let old = #"{"intranetURL":null,"expectedDNS":["223.5.5.5"],"notificationsEnabled":false,"legacyField":null}"#
                let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
                t.expectEqual(decoded.expectedDNS, ["223.5.5.5"])
                t.expectEqual(decoded.disconnectedDNSRule, .equals)
                t.expect(!decoded.notificationsEnabled)
                t.expectEqual(decoded.localCheckInterval, 20)
                t.expectEqual(decoded.lightProbeInterval, 120)
                t.expectEqual(decoded.sites, SiteCatalog.defaultSites)
                let oldSite = #"{"id":"custom","name":"测试","group":"japan","url":"https://example.com/","isKey":true,"inLightProbe":true}"#
                let migrated = try JSONDecoder().decode(Site.self, from: Data(oldSite.utf8))
                t.expect(migrated.isEnabled)
                t.expectEqual(migrated.group, .overseas)
                t.expectEqual(migrated.id, "custom")
                t.expectEqual(migrated.url.absoluteString, "https://example.com/")
                t.expectNotContains(String(data: try JSONEncoder().encode(migrated), encoding: .utf8) ?? "", "japan")
                var empty = decoded
                empty.sites = []
                t.expectEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(empty)).sites, [])
            },
            TestCase("周期和公开站点校验") { t in
                var settings = AppSettings(sites: [])
                t.expectEqual(SettingsValidator.validate(settings), [])
                settings.localCheckInterval = 5.5
                settings.lightProbeInterval = .infinity
                t.expectEqual(settings.effectiveLocalCheckInterval, 20)
                t.expectEqual(settings.effectiveLightProbeInterval, 120)
                t.expectEqual(SettingsValidator.validate(settings), [.localCheckIntervalInvalid, .lightProbeIntervalInvalid])
                let valid = Site(id: "custom", name: "自定义", group: .overseas,
                                 url: URL(string: "https://example.com/")!, isKey: true, inLightProbe: true)
                t.expectEqual(SettingsValidator.validateSites([valid]), [])
                t.expect(SettingsValidator.validateSites((0...20).map { index in
                    var site = valid
                    site.id = "site-\(index)"
                    return site
                }).contains(.tooManySites))
                var duplicate = valid
                duplicate.name = "   "
                duplicate.url = URL(string: "https://user:pass@example.com/")!
                let errors = SettingsValidator.validateSites([valid, duplicate])
                t.expect(errors.contains(.siteIDDuplicate("custom")))
                t.expect(errors.contains(.siteNameInvalid("custom")))
                t.expect(errors.contains(.siteURLCredentials("custom")))
                duplicate.url = URL(string: "ftp://example.com/")!
                t.expect(SettingsValidator.validateSites([duplicate]).contains(.siteURLInvalid("custom")))
                duplicate.id = SiteCatalog.intranetID
                duplicate.group = .intranet
                t.expect(SettingsValidator.validateSites([duplicate]).contains(.siteIDInvalid))
                t.expect(SettingsValidator.validateSites([duplicate]).contains(.siteGroupInvalid("intranet")))
                duplicate.id = "custom"
                duplicate.group = SiteGroup(rawValue: "   ")
                t.expect(SettingsValidator.validateSites([duplicate]).contains(.siteGroupInvalid("custom")))
                duplicate.group = SiteGroup(rawValue: String(repeating: "组", count: 21))
                t.expect(SettingsValidator.validateSites([duplicate]).contains(.siteGroupInvalid("custom")))
                duplicate.group = SiteGroup(rawValue: "内网站点")
                t.expect(SettingsValidator.validateSites([duplicate]).contains(.siteGroupInvalid("custom")))
                duplicate.group = SiteGroup(rawValue: "东亚\n分组")
                t.expect(SettingsValidator.validateSites([duplicate]).contains(.siteGroupInvalid("custom")))
                duplicate.group = SiteGroup(rawValue: "东亚")
                duplicate.url = URL(string: "https://example.com/")!
                duplicate.name = "自定义"
                t.expectEqual(SettingsValidator.validateSites([duplicate]), [])
                t.expectContains(SettingsValidationError.siteURLInvalid("custom").message, "站点")
            },
            TestCase("SettingsStore 读写（独立 suite，结束后清理）") { t in
                let (suite, directory) = try makeTemporaryDefaultsSuite()
                defer { removeTemporaryDefaultsSuite(suite, directory: directory) }
                let store = SettingsStore(suiteName: suite)
                t.expectEqual(store.load(), AppSettings())

                let saved = AppSettings(
                    intranetURL: URL(string: "https://intranet.corp.example/health"),
                    expectedDNS: ["119.29.29.29", "223.5.5.5"],
                    notificationsEnabled: false)
                store.save(saved)
                t.expectEqual(SettingsStore(suiteName: suite).load(), saved)

                // 非法值回落到默认值。
                store.defaults.set("ftp://x", forKey: SettingsStore.Key.intranetURL)
                store.defaults.set(["bad"], forKey: SettingsStore.Key.expectedDNS)
                let fallback = store.load()
                t.expectNil(fallback.intranetURL)
                t.expectEqual(fallback.expectedDNS, [])
                t.expect(!fallback.notificationsEnabled)

                store.removeAll()
                t.expectEqual(store.load(), AppSettings())
                t.expectNil(store.defaults.object(forKey: SettingsStore.Key.notificationsEnabled))
            },
            TestCase("旧持久化设置迁移、空站点和损坏配置回退") { t in
                let (suite, directory) = try makeTemporaryDefaultsSuite()
                defer { removeTemporaryDefaultsSuite(suite, directory: directory) }
                let store = SettingsStore(suiteName: suite)
                store.defaults.set(["223.5.5.5"], forKey: SettingsStore.Key.expectedDNS)
                store.defaults.set(false, forKey: SettingsStore.Key.notificationsEnabled)
                var migrated = store.load()
                t.expectEqual(migrated.expectedDNS, ["223.5.5.5"])
                t.expect(!migrated.notificationsEnabled)
                t.expectEqual(migrated.sites, SiteCatalog.defaultSites)
                let legacySites = #"[{"id":"tokyo","name":"东京","group":"japan","url":"https://example.jp/","isKey":true,"inLightProbe":true},{"id":"custom","name":"自定义","group":"东亚","url":"https://example.com/","isKey":false,"inLightProbe":false}]"#
                store.defaults.set(Data(legacySites.utf8), forKey: SettingsStore.Key.sites)
                let migratedSites = store.load().sites
                t.expectEqual(migratedSites.map(\.id), ["tokyo", "custom"])
                t.expectEqual(migratedSites.map(\.group), [.overseas, SiteGroup(rawValue: "东亚")])
                t.expectEqual(migratedSites.first?.url.absoluteString, "https://example.jp/")
                migrated.sites = []
                migrated.localCheckInterval = 30
                migrated.lightProbeInterval = 180
                store.save(migrated)
                t.expectEqual(SettingsStore(suiteName: suite).load(), migrated)
                store.defaults.set(4.5, forKey: SettingsStore.Key.localCheckInterval)
                store.defaults.set(86401, forKey: SettingsStore.Key.lightProbeInterval)
                store.defaults.set(Data("broken".utf8), forKey: SettingsStore.Key.sites)
                let recovered = store.load()
                t.expectEqual(recovered.localCheckInterval, 20)
                t.expectEqual(recovered.lightProbeInterval, 120)
                t.expectEqual(recovered.sites, SiteCatalog.defaultSites)
                t.expectEqual(recovered.expectedDNS, ["223.5.5.5"])
            },
            TestCase("L5：单个站点不合法时只过滤该站点，并备份原始数据") { t in
                let (suite, directory) = try makeTemporaryDefaultsSuite()
                defer { removeTemporaryDefaultsSuite(suite, directory: directory) }
                let store = SettingsStore(suiteName: suite)
                let raw = #"[{"id":"custom","name":"自定义","group":"东亚","url":"https://example.com/","isKey":true,"inLightProbe":true},{"id":"ftp","name":"FTP","group":"海外","url":"ftp://example.net/","isKey":false,"inLightProbe":false},{"id":"broken","name":"缺字段"},{"id":"custom","name":"重复","group":"海外","url":"https://dup.example/","isKey":false,"inLightProbe":false},{"id":"baidu","name":"百度","group":"mainland","url":"https://www.baidu.com/","isKey":true,"inLightProbe":true,"isEnabled":false}]"#
                store.defaults.set(Data(raw.utf8), forKey: SettingsStore.Key.sites)
                let sites = store.load().sites
                t.expectEqual(sites.map(\.id), ["custom", "baidu"])
                t.expectEqual(sites.first?.group, SiteGroup(rawValue: "东亚"))
                t.expectEqual(sites.last?.isEnabled, false)
                t.expectEqual(store.defaults.data(forKey: SettingsStore.Key.sitesInvalidBackup), Data(raw.utf8))
                t.expectEqual(store.defaults.data(forKey: SettingsStore.Key.sites), Data(raw.utf8), "读取不改写原始站点数据")
            },
            TestCase("L5：整份站点数据无法解码时回落默认值，并备份原始数据") { t in
                let (suite, directory) = try makeTemporaryDefaultsSuite()
                defer { removeTemporaryDefaultsSuite(suite, directory: directory) }
                let store = SettingsStore(suiteName: suite)
                store.defaults.set(Data("broken".utf8), forKey: SettingsStore.Key.sites)
                t.expectEqual(store.load().sites, SiteCatalog.defaultSites)
                t.expectEqual(store.defaults.data(forKey: SettingsStore.Key.sitesInvalidBackup), Data("broken".utf8))

                let valid = try JSONEncoder().encode([SiteCatalog.google])
                store.defaults.set(valid, forKey: SettingsStore.Key.sites)
                store.defaults.removeObject(forKey: SettingsStore.Key.sitesInvalidBackup)
                t.expectEqual(store.load().sites, [SiteCatalog.google])
                t.expectNil(store.defaults.data(forKey: SettingsStore.Key.sitesInvalidBackup), "合法数据不产生备份")
                store.removeAll()
                t.expectNil(store.defaults.data(forKey: SettingsStore.Key.sites))
            },
        ])
    }
}

enum DiagnosticsTests {
    typealias F = FixtureLoader
    static let intranetURL = URL(string: "https://Intranet.Corp.Example/health")!

    static var suite: TestSuite {
        TestSuite("Core.Diagnostics", [
            TestCase("Redactor：内网 IP 只保留首段") { t in
                let r = Redactor()
                t.expectEqual(r.redact("DNS 10.9.0.53, 10.9.0.54"), "DNS 10.x.x.x, 10.x.x.x")
                t.expectEqual(r.redact("路由器 192.168.0.1。"), "路由器 192.x.x.x。")
                t.expectEqual(r.redact("172.16.5.4 与 172.32.0.1"), "172.x.x.x 与 172.32.0.1")
                t.expectEqual(r.redact("Tailscale 100.64.0.2"), "Tailscale 100.x.x.x")
                t.expectEqual(r.redact("网段 10.9.0.0/16"), "网段 10.x.x.x/16")
                let untouched = "119.29.29.29 198.18.0.1 127.0.0.1 8.8.8.8 142.250.0.1 版本 1.2.3 与 10.1.2.3.4"
                t.expectEqual(r.redact(untouched), untouched)
            },
            TestCase("Redactor：去掉主目录路径") { t in
                let r = Redactor(homeDirectory: "/Users/tester")
                t.expectEqual(r.redact("/Users/tester/Library/Application Support/x"), "~/Library/Application Support/x")
                t.expectEqual(Redactor().redact("路径 /Users/alice/Library 与 /Users/bob"), "路径 ~/Library 与 ~")
            },
            TestCase("M2：内置站点主机名不替换系统解析证据，完整 URL 仍替换") { t in
                let r = Redactor(siteURLs: FixtureLoader.legacySites.map(\.url))
                let evidence = "系统解析 www.google.com 返回 fake-ip 198.18.0.26"
                t.expectEqual(r.redact(evidence), evidence)
                t.expectEqual(r.redact("请求 https://www.google.com/generate_204 超时"), "请求 [检测站点] 超时")
            },
            TestCase("M2：自定义主机名按边界替换，短主机名跳过") { t in
                let custom = URL(string: "https://status.corp-internal.example/health")!
                let r = Redactor(siteURLs: [custom, URL(string: "https://dns/")!])
                t.expectEqual(r.redact("连接 status.corp-internal.example 失败（STATUS.CORP-INTERNAL.EXAMPLE:443）"),
                              "连接 [检测站点] 失败（[检测站点]:443）")
                t.expectEqual(r.redact("无法访问 status.corp-internal.example。"), "无法访问 [检测站点]。")
                let neighbours = "mystatus.corp-internal.example 与 status.corp-internal.example.cn"
                t.expectEqual(r.redact(neighbours), neighbours)
                let dnsText = "Mihomo DNS 7874 端口，dnsmasq 与 /etc/dns"
                t.expectEqual(r.redact(dnsText), dnsText)
            },
            TestCase("M2：数字或 IP 形式的主机名不破坏私网 IP 脱敏") { t in
                let r = Redactor(siteURLs: [URL(string: "http://192/")!, URL(string: "http://10.1.2.3/")!])
                t.expectEqual(r.redact("路由器 192.168.0.1"), "路由器 192.x.x.x")
                t.expectEqual(r.redact("请求 http://10.1.2.3/ 超时"), "请求 http://10.x.x.x/ 超时")
                t.expectEqual(r.redact("192 个请求"), "192 个请求")
            },
            TestCase("Redactor：不输出内网站点 URL（不区分大小写）") { t in
                let r = Redactor(intranetURL: intranetURL)
                let text = r.redact("探测 https://Intranet.Corp.Example/health 失败；主机 intranet.corp.example 无响应")
                t.expectNotContains(text.lowercased(), "corp.example")
                t.expectContains(text, Redactor.intranetPlaceholder)
            },
            TestCase("诊断摘要包含计划列出的字段且已脱敏") { t in
                let local = F.evaluate(try F.snapshot(.c))
                var history = SiteHistory()
                let google = SiteCatalog.google
                for outcome in [RequestOutcome.http(status: 204, latency: 0.18), .failure(.timeout), .http(status: 204, latency: 0.2)] {
                    history.record(SiteAggregator.aggregate(site: google, outcomes: [outcome], checkedAt: F.collectedAt))
                }
                let intranetSite = SiteCatalog.intranet(url: intranetURL)
                history.record(SiteAggregator.aggregate(site: intranetSite, outcomes: [.failure(.timeout)], checkedAt: F.collectedAt))
                let overall = OverallAssessment(local: local, connectivityFaults: [])
                var entries = DiagnosticSummary.siteEntries(history: history)
                entries.append(DiagnosticSummary.SiteEntry(site: intranetSite, history: history.recent(for: "intranet")))
                let summary = DiagnosticSummary(
                    generatedAt: F.collectedAt, appVersion: "0.1.0", osVersion: "26.6.2",
                    overall: overall, local: local, sites: entries, intranetConfigured: true)
                let text = summary.render(redactor: Redactor(homeDirectory: F.testHome, intranetURL: intranetURL),
                                          timeZone: TimeZone(identifier: "Asia/Shanghai")!)
                t.expectContains(text, "生成时间：2026-09-26 20:00:00")
                t.expectContains(text, "应用版本：0.1.0")
                t.expectContains(text, "macOS 版本：26.6.2")
                t.expectContains(text, "总体状态：故障")
                t.expectContains(text, "[故障] Wi-Fi DNS：VPN 已断开、TUN 运行中，DNS 未恢复为 119.29.29.29")
                t.expectContains(text, "提示：等待 VPN 完全断开后，关闭并重新开启 Clash TUN")
                t.expectContains(text, "· 保存值：空（DNS 已被清空）")
                t.expectContains(text, "Google：可达，200 ms；最近 3 次：可达 / 超时 / 可达")
                t.expectContains(text, "百度：尚未检测")
                t.expectContains(text, "内网站点：已配置；超时；最近 1 次：超时")
                t.expectContains(text, "生效 DNS：192.x.x.x")
                t.expectNotContains(text.lowercased(), "corp.example")
                t.expectNotContains(text, "10.231")
                t.expectNotContains(text, "/Users/")
                t.expectNotContains(text, "example-tailnet")
                t.expectNotContains(text, "ts.net")
                t.expectContains(text, "家庭子网：未配置")
            },
            TestCase("诊断摘要：未配置内网") { t in
                let summary = DiagnosticSummary(
                    generatedAt: F.collectedAt, appVersion: "0.1.0", osVersion: "26.6.2",
                    overall: OverallAssessment(local: nil, connectivityFaults: []), local: nil,
                    sites: DiagnosticSummary.siteEntries(history: SiteHistory()), intranetConfigured: false,
                    intranetSkippedText: "未验证")
                let text = summary.render(redactor: Redactor())
                t.expectContains(text, "内网站点：未配置（未验证）")
                t.expectContains(text, "总体状态：未确认")
            },
            TestCase("手动恢复步骤：5 步，带服务名") { t in
                let steps = RecoveryGuide.steps(serviceName: "Wi-Fi")
                t.expectEqual(steps.count, 5)
                t.expect(steps[0].hasPrefix("确认 VPN 已完全断开"))
                t.expectContains(steps[1], "关闭 TUN")
                t.expectContains(steps[2], "networksetup -getdnsservers Wi-Fi")
                t.expectContains(steps[3], "系统设置 → 网络 → 对应服务 → 详细信息 → DNS")
                t.expectContains(steps[4], "立即复测")
                t.expectContains(RecoveryGuide.steps(serviceName: "USB 10/100/1000 LAN")[2],
                                 "networksetup -getdnsservers \"USB 10/100/1000 LAN\"")
                t.expectContains(RecoveryGuide.steps(serviceName: nil)[2], "<服务名>")
                let rendered = RecoveryGuide.render(serviceName: "Wi-Fi")
                t.expect(rendered.hasPrefix("手动恢复步骤\n1. "))
                t.expectContains(rendered, "\n5. ")
            },
        ])
    }
}
