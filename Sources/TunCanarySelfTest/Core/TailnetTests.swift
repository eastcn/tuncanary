import Foundation
import TunCanaryCore

/// Tailnet 卡、Tailnet 子网目标与路由查询。全部使用合成数据。
enum TailnetTests {
    static let tailscale = InterfaceInfo(name: "utun3", isUp: true, ipv4Addresses: [IPv4("100.80.1.2")!])
    static let proxyTun = InterfaceInfo(name: "utun1024", isUp: true, ipv4Addresses: [IPv4("198.18.0.1")!])
    static let lan = InterfaceInfo(name: "en0", isUp: true, ipv4Addresses: [IPv4("192.168.1.20")!])
    static let fakeRange = IPv4CIDR("198.18.0.1/16")!

    static func route(_ destination: String, _ interface: String, flags: String = "UCS",
                      gateway: String = "link#1") -> RouteEntry {
        RouteEntry(destination: destination, gateway: gateway, flags: flags, interfaceName: interface)
    }

    /// 在外面：Tailscale 接受了 Tailnet 子网 10.20/16 的路由，代理 TUN 接管其余流量。
    static let awayRoutes: [RouteEntry] = [
        route("default", "en0", flags: "UGScg", gateway: "192.168.1.1"),
        route("default", "utun3", flags: "UCSIg"),
        route("1", "utun1024", flags: "UGSc", gateway: "198.18.0.1"),
        route("8/5", "utun1024", flags: "UGSc", gateway: "198.18.0.1"),
        route("64/2", "utun1024", flags: "UGSc", gateway: "198.18.0.1"),
        route("100.64/10", "utun3"),
        route("100.100.100.100/32", "utun3"),
        route("10.20/16", "utun3"),
        route("192.168.1", "en0"),
        route("192.168.1.40", "en0", flags: "UHLWI", gateway: "xx:xx:xx:xx:xx:xx"),
    ]

    static let magicResolver = Resolver(isScoped: false, number: 8, domain: "example-tailnet.ts.net",
                                        nameservers: ["100.100.100.100"])

    static func snapshot(interfaces: [InterfaceInfo] = [proxyTun, lan, tailscale],
                         routes: [RouteEntry] = awayRoutes,
                         resolvers: [Resolver] = [magicResolver],
                         tailnet: Collected<TailnetProbeSnapshot> = .notCollected) -> LocalSnapshot {
        // 以“TUN 运行、系统解析返回 fake-ip、没有 VPN”的正常快照为基础。
        var base = DNSRuleTests.snapshot(saved: ["192.0.2.53"])
        base.interfaces = .collected(interfaces)
        base.routes = .collected(routes)
        base.resolvers = .collected(resolvers)
        base.tailnet = tailnet
        return base
    }

    static func verified(_ forward: CanaryResult?) -> Collected<TailnetProbeSnapshot> {
        .collected(TailnetProbeSnapshot(selfAddress: IPv4("100.80.1.2")!,
                                        reverse: .answered(name: "laptop.example-tailnet.ts.net"),
                                        forward: forward))
    }

    static func analyze(_ snapshot: LocalSnapshot, target: String? = nil) -> TailnetProbeResultView {
        let settings = AppSettings(tailnetTarget: target.flatMap(TailnetTarget.init))
        let assessment = LocalEvaluator(paths: KnownPaths(homeDirectory: "/Users/tester"))
            .evaluate(snapshot: snapshot, settings: settings, inGracePeriod: false)
        return TailnetProbeResultView(card: assessment.card(.tailnet), decision: assessment.tailnetDecision,
                                      assessment: assessment)
    }

    struct TailnetProbeResultView {
        var card: StatusCard?
        var decision: TailnetProbeDecision
        var assessment: LocalAssessment
    }

    static var suite: TestSuite {
        TestSuite("Core.Tailnet", [
            TestCase("Tailnet 子网目标：只接受 IPv4:端口，编码为字符串") { t in
                let target = try t.require(TailnetTarget("192.0.2.10:443"))
                t.expectEqual(target.description, "192.0.2.10:443")
                t.expectEqual(target.url.absoluteString, "tcp://192.0.2.10:443")
                t.expectEqual(TailnetTarget(url: target.url), target)
                t.expectNil(TailnetTarget("nas.example:443"))
                t.expectNil(TailnetTarget("192.0.2.10"))
                t.expectNil(TailnetTarget("192.0.2.10:0"))
                t.expectNil(TailnetTarget("192.0.2.10:65536"))
                t.expectNil(TailnetTarget("192.0.2.10:+80"))
                t.expectNil(TailnetTarget(url: URL(string: "https://192.0.2.10:443/")!))
                let data = try JSONEncoder().encode(AppSettings(tailnetTarget: target))
                let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
                t.expectEqual(decoded.tailnetTarget, target)
                if case .failure(let error) = SettingsValidator.validateTailnetTarget("nas:1") {
                    t.expectEqual(error, .tailnetTargetInvalid)
                } else {
                    t.expect(false, "域名应校验失败")
                }
                if case .success(let empty) = SettingsValidator.validateTailnetTarget("  ") {
                    t.expectNil(empty)
                } else {
                    t.expect(false, "空串表示未配置")
                }
            },
            TestCase("路由查询：最长前缀，忽略限定作用域的路由") { t in
                t.expectEqual(RouteLookup.bestRoute(for: IPv4("100.100.100.100")!, in: awayRoutes)?.interfaceName, "utun3")
                t.expectEqual(RouteLookup.bestRoute(for: IPv4("10.20.0.5")!, in: awayRoutes)?.interfaceName, "utun3")
                t.expectEqual(RouteLookup.bestRoute(for: IPv4("10.30.0.5")!, in: awayRoutes)?.interfaceName, "utun1024")
                t.expectEqual(RouteLookup.bestRoute(for: IPv4("172.30.0.5")!, in: awayRoutes)?.destination, "default")
                t.expectEqual(RouteLookup.bestRoute(for: IPv4("172.30.0.5")!, in: awayRoutes)?.interfaceName, "en0")
                // 限定作用域的主机路由不参与匹配，命中直连网段。
                t.expectEqual(RouteLookup.bestRoute(for: IPv4("192.168.1.40")!, in: awayRoutes)?.destination, "192.168.1")
                t.expectNil(RouteLookup.bestRoute(for: IPv4("10.20.0.5")!, in: [route("default", "utun3", flags: "UCSIg")]))
            },
            TestCase("没有 Tailscale 也没配目标：不显示卡片") { t in
                let result = analyze(snapshot(interfaces: [proxyTun, lan]))
                t.expectNil(result.card)
                t.expectEqual(result.decision, .notConfigured)
                t.expectEqual(result.assessment.cards.count, 4)
            },
            TestCase("配了目标但 Tailscale 未连接：灰，不拉低整体，不列为原因") { t in
                let result = analyze(snapshot(interfaces: [proxyTun, lan]), target: "10.20.0.10:443")
                let card = try t.require(result.card)
                t.expectEqual(card.severity, .unknown)
                t.expectEqual(card.conclusion, "未连接 Tailscale")
                t.expectEqual(result.decision, .tailscaleDown)
                t.expect(!card.countsTowardOverall)
                t.expect(result.assessment.reasons.allSatisfy { $0.text != card.line })
            },
            TestCase("tailnet 路由被代理 TUN 抢走：红 tailnet.route") { t in
                let routes = awayRoutes.filter { !$0.destination.hasPrefix("100.") }
                let result = analyze(snapshot(routes: routes), target: "10.20.0.10:443")
                let card = try t.require(result.card)
                t.expectEqual(card.severity, .critical)
                t.expectEqual(card.faultKey, .tailnetRoute)
                t.expectEqual(result.decision, .routeUnavailable)
                t.expectContains(card.evidence.joined(separator: "\n"), "MagicDNS 地址经 utun1024（代理 TUN），不是 utun3")
                t.expectEqual(result.assessment.severity, .critical)
            },
            TestCase("路由表中没有任何匹配：证据不足") { t in
                let result = analyze(snapshot(routes: [route("10.20/16", "utun3")]))
                let card = try t.require(result.card)
                t.expectEqual(card.severity, .unknown)
                t.expectEqual(card.conclusion, "证据不足：路由表不完整")
            },
            TestCase("MagicDNS：名称解析回本机为正常，fake-ip 或无响应为黄") { t in
                let ok = try t.require(analyze(snapshot(tailnet: verified(.resolved([IPv4("100.80.1.2")!])))).card)
                t.expectEqual(ok.severity, .ok)
                t.expectEqual(ok.conclusion, "已连接（utun3），MagicDNS 正常")
                t.expectNotContains(ok.evidence.joined(), "ts.net")

                let hijacked = try t.require(analyze(snapshot(tailnet: verified(.resolved([IPv4("198.18.0.40")!])))).card)
                t.expectEqual(hijacked.severity, .warning)
                t.expectEqual(hijacked.faultKey, .tailnetMagicDNS)
                t.expectContains(hijacked.conclusion, "被代理截获")

                let silent = try t.require(analyze(snapshot(tailnet: .collected(TailnetProbeSnapshot(
                    selfAddress: IPv4("100.80.1.2")!, reverse: .timedOut)))).card)
                t.expectEqual(silent.severity, .warning)
                t.expectEqual(silent.conclusion, "MagicDNS 无响应（反查超时）")

                let failed = try t.require(analyze(snapshot(tailnet: verified(.failed(reason: "没有这个主机名")))).card)
                t.expectEqual(failed.severity, .warning)

                // 没有 MagicDNS 解析器：不检查，也不说“MagicDNS 正常”。
                let disabled = try t.require(analyze(snapshot(resolvers: [])).card)
                t.expectEqual(disabled.severity, .ok)
                t.expectEqual(disabled.conclusion, "已连接（utun3）")
                t.expectContains(disabled.evidence.joined(separator: "\n"), "未启用 MagicDNS")
            },
            TestCase("Tailnet 子网：经 Tailscale 时探测") { t in
                let result = analyze(snapshot(), target: "10.20.0.10:443")
                t.expectEqual(result.decision.site?.url.absoluteString, "tcp://10.20.0.10:443")
                t.expectEqual(result.decision.site?.group, .tailnet)
                t.expectEqual(result.card?.severity, .ok)
                t.expectContains(result.card?.evidence.joined(separator: "\n") ?? "", "Tailnet 子网 10.20.0.10 经 utun3（Tailscale）")
            },
            TestCase("Tailnet 子网：与当前网络同网段时判灰，不探测，整体仍为绿") { t in
                let result = analyze(snapshot(), target: "192.168.1.40:443")
                t.expectEqual(result.decision, .sameSubnet)
                t.expectEqual(result.card?.severity, .unknown)
                t.expectEqual(result.card?.conclusion, "当前网络与 Tailnet 子网网段相同，不探测")
                t.expectEqual(result.assessment.severity, .ok)
                t.expectEqual(result.assessment.primaryReason, "各项检查正常")
            },
            TestCase("Tailnet 子网：经默认路由或代理 TUN 出去时，子网路由未生效，红") { t in
                let viaDefault = analyze(snapshot(), target: "172.30.0.5:443")
                t.expectEqual(viaDefault.decision, .routeUnavailable)
                t.expectEqual(viaDefault.card?.severity, .critical)
                t.expectEqual(viaDefault.card?.faultKey, .tailnetSubnetRoute)

                let viaProxy = analyze(snapshot(), target: "10.30.0.5:443")
                t.expectEqual(viaProxy.card?.conclusion, "Tailnet 子网 10.30.0.5 经 utun1024（代理 TUN），子网路由未生效")
            },
            TestCase("宽限期内：Tailnet 子网决策为未确认") { t in
                let settings = AppSettings(tailnetTarget: TailnetTarget("10.20.0.10:443"))
                let assessment = LocalEvaluator(paths: KnownPaths(homeDirectory: "/Users/tester"))
                    .evaluate(snapshot: snapshot(), settings: settings, inGracePeriod: true)
                t.expectEqual(assessment.tailnetDecision, .unconfirmed)
            },
            TestCase("Tailnet 子网连续三轮失败为红；不满足条件时计数清零") { t in
                let site = SiteCatalog.tailnet(target: TailnetTarget("10.20.0.10:443")!)
                let failed = SiteResult(site: site, category: .timeout, medianLatency: nil,
                                        attempts: [.failure(.timeout)], checkedAt: Date())
                var tracker = ConnectivityTracker()
                for _ in 0..<2 { tracker.recordRound([failed], intranetEligible: false, tailnetEligible: true) }
                t.expectEqual(tracker.faults(sites: [site]), [])
                tracker.recordRound([failed], intranetEligible: false, tailnetEligible: true)
                let fault = try t.require(tracker.faults(sites: [site]).first)
                t.expectEqual(fault.key, .site("tailnet"))
                t.expectEqual(fault.severity, .critical)
                t.expectEqual(fault.message, "Tailnet 子网连续三轮访问失败")
                tracker.recordRound([], intranetEligible: false, tailnetEligible: false)
                t.expectEqual(tracker.failureCount(for: SiteCatalog.tailnetID), 0)
            },
            TestCase("本地网络权限被拒不计失败；TCP 延迟计入中位数") { t in
                let site = SiteCatalog.tailnet(target: TailnetTarget("10.20.0.10:443")!)
                let denied = SiteAggregator.aggregate(site: site, outcomes: [.failure(.localNetworkDenied)], checkedAt: Date())
                t.expect(!denied.isFailure)
                t.expectEqual(denied.summaryText, "未获得本地网络权限")
                let answered = SiteAggregator.aggregate(
                    site: site, outcomes: [.tcpAnswered(latency: 0.012, refused: true)], checkedAt: Date())
                t.expectEqual(answered.summaryText, "可达 12 ms")
            },
            TestCase("命令行：Tailnet 灰色不影响退出码；Tailnet 子网失败判红") { t in
                let home = analyze(snapshot(), target: "192.168.1.40:443")
                let gray = CLIVerdict.make(firstLocal: home.assessment, secondLocal: nil, siteResults: [],
                                           intranet: .notConfigured, tailnet: home.decision, full: false,
                                           checkedAt: Date(timeIntervalSince1970: 1_790_424_000), configuredSites: [])
                t.expectEqual(gray.exitCode, .ok)
                let text = gray.renderText(redactor: Redactor())
                t.expectContains(text, "[未确认] Tailnet：当前网络与 Tailnet 子网网段相同，不探测")
                t.expectContains(text, "Tailnet 子网 当前网络与 Tailnet 子网网段相同")
                let json = gray.renderJSON(redactor: Redactor())
                let object = try t.require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                let tailnet = try t.require(object["tailnet"] as? [String: Any])
                t.expectEqual(tailnet["configured"] as? Bool, true)
                t.expectEqual(tailnet["status"] as? String, "sameSubnet")
                t.expectNotContains(json, "192.168.1.40")

                let away = analyze(snapshot(), target: "10.20.0.10:443")
                let site = try t.require(away.decision.site)
                let down = SiteAggregator.aggregate(site: site, outcomes: [.failure(.timeout), .failure(.timeout)],
                                                    checkedAt: Date())
                let red = CLIVerdict.make(firstLocal: away.assessment, secondLocal: nil, siteResults: [down],
                                          intranet: .notConfigured, tailnet: away.decision, full: false,
                                          checkedAt: Date(timeIntervalSince1970: 1_790_424_000), configuredSites: [])
                t.expectEqual(red.exitCode, .critical)
                t.expectEqual(red.faults.map(\.key), [.site("tailnet")])
                t.expectContains(red.renderText(redactor: Redactor()), "Tailnet 子网 超时")
            },
            TestCase("站点清单：Tailnet 子网只在满足条件时加入，保留 ID 不能用于公开站点") { t in
                let site = SiteCatalog.tailnet(target: TailnetTarget("10.20.0.10:443")!)
                let light = SiteCatalog.lightProbeSites(intranet: .notConfigured, tailnet: .probe(site))
                t.expectEqual(light.last, site)
                t.expect(!SiteCatalog.lightProbeSites(intranet: .notConfigured, tailnet: .sameSubnet).contains(site))
                t.expect(!SiteGroup.tailnet.isValidPublicGroup)
                t.expect(!SiteGroup(rawValue: "Tailnet 子网").isValidPublicGroup)
                var reserved = SiteCatalog.google
                reserved.id = SiteCatalog.tailnetID
                t.expect(SettingsValidator.validateSites([reserved]).contains(.siteIDInvalid))
            },
        ])
    }
}
