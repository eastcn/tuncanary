import Foundation
import TunCanaryCore

enum CLITests {
    typealias F = FixtureLoader
    static let now = FixtureLoader.collectedAt
    static let intranetURL = URL(string: "https://intranet.corp.example/health")!
    static let redactor = Redactor(homeDirectory: FixtureLoader.testHome, intranetURL: intranetURL)

    static func site(_ site: Site, _ outcomes: [RequestOutcome]) -> SiteResult {
        SiteAggregator.aggregate(site: site, outcomes: outcomes, checkedAt: now)
    }

    /// 计划输出示例中的轻测结果：百度 35 ms、Google 180 ms、Claude 403。
    static var exampleLight: [SiteResult] {
        [
            site(SiteCatalog.baidu, [.http(status: 200, latency: 0.035)]),
            site(SiteCatalog.google, [.http(status: 204, latency: 0.180)]),
            site(SiteCatalog.claude, [.http(status: 403, latency: 0.250)]),
        ]
    }

    static func verdict(
        _ first: LocalAssessment,
        _ second: LocalAssessment? = nil,
        sites: [SiteResult] = exampleLight,
        intranet: IntranetProbeDecision = .notConfigured,
        full: Bool = false,
        configuredSites: [Site] = FixtureLoader.legacySites
    ) -> CLIVerdict {
        CLIVerdict.make(firstLocal: first, secondLocal: second, siteResults: sites,
                        intranet: intranet, full: full, checkedAt: now,
                        configuredSites: configuredSites)
    }

    static var suite: TestSuite {
        TestSuite("Core.CLI", [
            // MARK: 参数

            TestCase("参数解析与参数错误 64") { t in
                t.expectEqual(CommandLineParser.parse([]), .app)
                t.expectEqual(CommandLineParser.parse(["-psn_0_12345"]), .app)
                t.expectEqual(CommandLineParser.parse(["--check"]), .check(CheckOptions(full: false, json: false)))
                t.expectEqual(CommandLineParser.parse(["--check", "--full", "--json"]), .check(CheckOptions(full: true, json: true)))
                t.expectEqual(CommandLineParser.parse(["--json", "--check"]), .check(CheckOptions(full: false, json: true)))
                t.expectEqual(CommandLineParser.parse(["--help"]), .help)
                if case .usageError = CommandLineParser.parse(["--check", "--bogus"]) {} else { t.fail("未知参数应报错") }
                if case .usageError = CommandLineParser.parse(["--json"]) {} else { t.fail("--json 需配合 --check") }
                t.expectEqual(CLIExitCode.usage.rawValue, 64)
            },
            TestCase("M3：界面模式只放行系统参数，其余短横线参数返回 64") { t in
                t.expectEqual(CommandLineParser.parse(["-NSDocumentRevisionsDebugMode", "YES"]), .app)
                t.expectEqual(CommandLineParser.parse(["-AppleLanguages", "(zh-Hans)", "-psn_0_12345"]), .app)
                t.expectEqual(CommandLineParser.parse(["-ApplePersistenceIgnoreState", "-1"]), .app)
                for arguments in [["--chek"], ["-x"], ["--fulll"], ["-psn_0_1", "--jsn"], ["-NSQuitAlwaysKeepsWindows", "NO", "-v"]] {
                    if case .usageError(let message) = CommandLineParser.parse(arguments) {
                        t.expectContains(message, arguments.last!)
                    } else {
                        t.fail("\(arguments) 应返回参数错误")
                    }
                }
            },
            TestCase("退出码映射 0/1/2/3") { t in
                t.expectEqual(CLIExitCode(severity: .ok).rawValue, 0)
                t.expectEqual(CLIExitCode(severity: .warning).rawValue, 1)
                t.expectEqual(CLIExitCode(severity: .critical).rawValue, 2)
                t.expectEqual(CLIExitCode(severity: .unknown).rawValue, 3)
            },

            // MARK: 本机

            TestCase("A 组 + 轻测正常 → 0") { t in
                let result = verdict(F.evaluate(try F.snapshot(.a)))
                t.expectEqual(result.exitCode, .ok)
                t.expect(result.renderText(redactor: redactor).hasPrefix("状态：正常（退出码 0）"))
            },
            TestCase("C 组两次一致 → 2，输出与计划示例一致") { t in
                let first = F.evaluate(try F.snapshot(.c))
                let second = F.evaluate(try F.snapshot(.c))
                let result = verdict(first, second)
                t.expectEqual(result.exitCode, .critical)
                t.expect(result.localConfirmed)
                let expected = """
                状态：故障（退出码 2）
                [故障] 主网络 DNS（Wi-Fi）：VPN 已断开、TUN 运行中，DNS 未恢复为 119.29.29.29
                [正常] Clash TUN：配置开启，utun1024 存在
                [正常] Mihomo DNS：7874 端口响应 8 ms
                [正常] Example VPN：已断开
                [正常] 百度 可达 35 ms / Google 可达 180 ms / Claude 有响应（访问受限）
                """
                t.expectEqual(result.renderText(redactor: redactor), expected)
            },
            TestCase("黄或红两次不一致 → 3（未确认）") { t in
                let first = F.evaluate(try F.snapshot(.c))
                let changed = verdict(first, F.evaluate(try F.snapshot(.a)))
                t.expectEqual(changed.exitCode, .unconfirmed)
                t.expect(!changed.localConfirmed)
                t.expectContains(changed.renderText(redactor: redactor), "[未确认] 本机检查：两次采样结果不一致")
                t.expectEqual(changed.faults, [])
                // 缺少第二次采样也判为未确认。
                t.expectEqual(verdict(first, nil).exitCode, .unconfirmed)
                // 同为黄但故障键不同。
                let tunInactive = F.withoutInterface(try F.snapshot(.a), "utun1024")
                var mihomoDown = try F.snapshot(.a)
                mihomoDown.mihomoDNS = .noResponse(port: 7874)
                let yellowA = F.evaluate(tunInactive)
                let yellowB = F.evaluate(mihomoDown)
                t.expectEqual(yellowA.severity, yellowB.severity)
                t.expectEqual(verdict(yellowA, yellowB).exitCode, .unconfirmed)
            },
            TestCase("本机黄两次一致 → 1；本机灰 → 3") { t in
                var mihomoDown = try F.snapshot(.a)
                mihomoDown.mihomoDNS = .noResponse(port: 7874)
                let yellow = F.evaluate(mihomoDown)
                t.expectEqual(verdict(yellow, yellow).exitCode, .warning)

                var unreadable = try F.snapshot(.a)
                unreadable.clashConfig = .failed(reason: "不可读")
                let grey = F.evaluate(unreadable)
                t.expectEqual(verdict(grey).exitCode, .unconfirmed)
                // 灰 + 关键站点失败 → 黄优先于灰。
                let googleDown = [site(SiteCatalog.google, [.failure(.timeout), .failure(.timeout)])]
                t.expectEqual(verdict(grey, sites: googleDown).exitCode, .warning)
            },

            // MARK: 轻测

            TestCase("关键站点两次都失败才算失败") { t in
                let local = F.evaluate(try F.snapshot(.a))
                let once = [site(SiteCatalog.google, [.failure(.timeout), .http(status: 204, latency: 0.2)])]
                t.expectEqual(verdict(local, sites: once).exitCode, .ok)
                let restricted = [site(SiteCatalog.claude, [.failure(.timeout), .http(status: 403, latency: 0.2)])]
                t.expectEqual(verdict(local, sites: restricted).exitCode, .ok)
                let twice = [site(SiteCatalog.google, [.failure(.timeout), .failure(.dnsFailure)])]
                let result = verdict(local, sites: twice)
                t.expectEqual(result.exitCode, .warning)
                t.expectEqual(result.primaryReason, "Google 两次请求均失败")
            },
            TestCase("分组关键站点全部失败 → 2") { t in
                let local = F.evaluate(try F.snapshot(.a))
                let baidu = [site(SiteCatalog.baidu, [.failure(.connectionFailure), .failure(.connectionFailure)])]
                t.expectEqual(verdict(local, sites: baidu).exitCode, .critical)
                let overseas = [
                    site(SiteCatalog.google, [.failure(.timeout), .failure(.timeout)]),
                    site(SiteCatalog.github, [.failure(.tlsError), .failure(.tlsError)]),
                ]
                let result = verdict(local, sites: overseas, configuredSites: SiteCatalog.defaultSites)
                t.expectEqual(result.exitCode, .critical)
                t.expect(result.faults.map(\.key).contains(.group(.overseas)))
            },
            TestCase("完整检测 2 次 TLS 失败 1 次可达按汇总结果告警") { t in
                let local = F.evaluate(try F.snapshot(.a))
                let claude = site(SiteCatalog.github, [
                    .failure(.tlsError), .failure(.tlsError), .http(status: 200, latency: 0.15),
                ])
                t.expectEqual(claude.category, .tlsError)
                let result = verdict(local, sites: [claude], full: true, configuredSites: SiteCatalog.defaultSites)
                t.expectEqual(result.exitCode, .warning)
                t.expectEqual(result.primaryReason, "GitHub 完整检测失败")
                t.expectEqual(result.faults.map(\.key), [.site(SiteCatalog.github.id)])
                t.expectContains(result.renderText(redactor: redactor), "[需关注] 海外：GitHub TLS 错误")

                let json = result.renderJSON(redactor: redactor)
                let object = try t.require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                let sites = try t.require(object["sites"] as? [[String: Any]])
                t.expectEqual(sites.first?["failed"] as? Bool, true)
                t.expectEqual(object["exitCode"] as? Int, 1)
            },
            TestCase("CLI 使用自定义关键站点配置判定且只展示传入结果") { t in
                let local = F.evaluate(try F.snapshot(.a))
                let custom = Site(id: "tokyo", name: "东京", group: SiteGroup(rawValue: "东亚"),
                                  url: URL(string: "https://tokyo.example/")!, isKey: true, inLightProbe: true)
                var disabled = SiteCatalog.baidu
                disabled.isEnabled = false
                let result = verdict(local, sites: [site(custom, [.failure(.timeout), .failure(.timeout)])],
                                     configuredSites: [custom, disabled])
                t.expectEqual(result.exitCode, .critical)
                t.expect(result.faults.map(\.key).contains(.group(SiteGroup(rawValue: "东亚"))))
                let text = result.renderText(redactor: redactor)
                t.expectContains(text, "东京 超时")
                t.expectNotContains(text, "百度")
                let object = try t.require(try JSONSerialization.jsonObject(with: Data(result.renderJSON(redactor: redactor).utf8)) as? [String: Any])
                let sites = try t.require(object["sites"] as? [[String: Any]])
                t.expectEqual(sites.map { $0["id"] as? String }, ["tokyo"])
            },
            TestCase("内网站点：连接时失败为 1，断开时不计") { t in
                let local = F.evaluate(try F.snapshot(.b))
                let intranetSite = SiteCatalog.intranet(url: intranetURL)
                let failing = exampleLight + [site(intranetSite, [.failure(.timeout), .failure(.timeout)])]
                let connected = verdict(local, sites: failing, intranet: .probe(intranetSite))
                t.expectEqual(connected.exitCode, .warning)
                let disconnected = verdict(local, sites: failing, intranet: .vpnDisconnected)
                t.expectEqual(disconnected.exitCode, .ok)
                let text = connected.renderText(redactor: redactor)
                t.expectNotContains(text, "corp.example")
                t.expectContains(text, "内网站点 超时")
            },
            TestCase("整体超时 → 3") { t in
                let result = CLIVerdict.timedOut(checkedAt: now, full: false)
                t.expectEqual(result.exitCode, .unconfirmed)
                t.expectEqual(result.renderText(redactor: redactor),
                              "状态：未确认（退出码 3）\n[未确认] 检查超时（30 秒），本机检查未完成，未开始站点检测")
            },

            // MARK: 渲染

            TestCase("完整检测按分组输出，内网未连接时跳过") { t in
                let local = F.evaluate(try F.snapshot(.a))
                let sites = FixtureLoader.legacySites.map { s -> SiteResult in
                    s.id == "sony"
                        ? site(s, [.failure(.timeout), .failure(.timeout), .failure(.timeout)])
                        : site(s, [.http(status: 200, latency: 0.05), .http(status: 200, latency: 0.06), .http(status: 200, latency: 0.07)])
                }
                let result = verdict(local, sites: sites, intranet: .vpnDisconnected, full: true)
                t.expectEqual(result.exitCode, .ok, "非关键站点不参与告警")
                let text = result.renderText(redactor: redactor)
                t.expectContains(text, "[正常] 国内：百度 可达 60 ms / 哔哩哔哩 可达 60 ms / 京东 可达 60 ms")
                t.expectContains(text, "海外：Yahoo! Japan 可达 60 ms / Sony 超时 / Google 可达 60 ms")
                t.expectContains(text, "[跳过] 内网站点：未连接 VPN")
            },
            TestCase("JSON 输出脱敏且可解析") { t in
                let local = F.evaluate(try F.snapshot(.b))
                let intranetSite = SiteCatalog.intranet(url: intranetURL)
                let sites = exampleLight + [site(intranetSite, [.http(status: 200, latency: 0.02)])]
                let result = verdict(local, sites: sites, intranet: .probe(intranetSite))
                let json = result.renderJSON(redactor: redactor, timeZone: TimeZone(identifier: "UTC")!)
                t.expectNotContains(json, "corp.example")
                t.expectNotContains(json, "10.9.0.53")
                t.expectNotContains(json, "/Users/")
                t.expectContains(json, "10.x.x.x")
                let object = try t.require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                t.expectEqual(object["exitCode"] as? Int, 0)
                t.expectEqual(object["status"] as? String, "ok")
                t.expectEqual(object["mode"] as? String, "light")
                t.expectEqual(object["checkedAt"] as? String, "2026-09-26T12:00:00Z")
                t.expectEqual((object["items"] as? [Any])?.count, 4)
                t.expectEqual((object["sites"] as? [Any])?.count, 4)
                let intranet = try t.require(object["intranet"] as? [String: Any])
                t.expectEqual(intranet["configured"] as? Bool, true)
                t.expectEqual(intranet["status"] as? String, "probed")
            },
            TestCase("JSON：C 组故障键") { t in
                let first = F.evaluate(try F.snapshot(.c))
                let json = verdict(first, first).renderJSON(redactor: redactor)
                let object = try t.require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                t.expectEqual(object["exitCode"] as? Int, 2)
                let faults = try t.require(object["faults"] as? [[String: Any]])
                t.expectEqual(faults.compactMap { $0["key"] as? String }, ["dns.notRestored"])
                t.expectNotContains(json, "192.168.0.1")
            },
        ])
    }
}
