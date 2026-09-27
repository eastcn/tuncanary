import Foundation
import TunCanaryCore

enum ConnectivityTests {
    static let now = FixtureLoader.collectedAt
    static let intranetURL = URL(string: "https://intranet.corp.example/health")!

    static func result(_ site: Site, _ outcomes: [RequestOutcome]) -> SiteResult {
        SiteAggregator.aggregate(site: site, outcomes: outcomes, checkedAt: now)
    }

    static func ok(_ site: Site, _ latency: TimeInterval = 0.05) -> SiteResult {
        result(site, [.http(status: 200, latency: latency)])
    }

    static func fail(_ site: Site, _ category: ProbeCategory = .timeout) -> SiteResult {
        result(site, [.failure(category)])
    }

    static var suite: TestSuite {
        TestSuite("Core.Connectivity", [
            // MARK: 分类

            TestCase("HTTP 状态码分类") { t in
                for code in [200, 204, 301, 302, 399] {
                    t.expectEqual(ProbeCategory(httpStatus: code), .reachable, "\(code)")
                }
                for code in [400, 403, 404, 405, 429] {
                    t.expectEqual(ProbeCategory(httpStatus: code), .restricted, "\(code)")
                }
                for code in [500, 502, 503] {
                    t.expectEqual(ProbeCategory(httpStatus: code), .serverError, "\(code)")
                }
            },
            TestCase("是否计为告警失败：4xx 不计") { t in
                let failures = ProbeCategory.allCases.filter(\.countsAsFailure)
                t.expectEqual(Set(failures), [.serverError, .tlsError, .timeout, .dnsFailure, .connectionFailure])
                t.expect(!ProbeCategory.restricted.countsAsFailure)
                t.expect(!ProbeCategory.reachable.countsAsFailure)
                t.expectEqual(ProbeCategory.restricted.displayName, "有响应（访问受限）")
            },
            TestCase("URLError 分类") { t in
                t.expectEqual(ProbeCategory(urlErrorCode: .timedOut), .timeout)
                t.expectEqual(ProbeCategory(urlErrorCode: .cannotFindHost), .dnsFailure)
                t.expectEqual(ProbeCategory(urlErrorCode: .dnsLookupFailed), .dnsFailure)
                t.expectEqual(ProbeCategory(urlErrorCode: .secureConnectionFailed), .tlsError)
                t.expectEqual(ProbeCategory(urlErrorCode: .serverCertificateUntrusted), .tlsError)
                t.expectEqual(ProbeCategory(urlErrorCode: .cannotConnectToHost), .connectionFailure)
                t.expectEqual(ProbeCategory(urlErrorCode: .networkConnectionLost), .connectionFailure)
                t.expectEqual(ProbeCategory(urlErrorCode: .notConnectedToInternet), .connectionFailure)
            },

            // MARK: 站点表

            TestCase("站点表：9 个公开站点与可选内网") { t in
                let sites = FixtureLoader.legacySites
                t.expectEqual(sites.count, 9)
                t.expectEqual(Set(sites.map(\.id)).count, 9)
                t.expectEqual(sites.filter { $0.group == .mainland }.map(\.name), ["百度", "哔哩哔哩", "京东"])
                t.expectEqual(sites.filter { $0.group == .overseas }.map(\.name),
                              ["Yahoo! Japan", "Sony", "Google", "GitHub", "Claude", "ChatGPT"])
                t.expectEqual(SiteGroup.publicGroups(for: sites), [.mainland, .overseas])
                t.expectEqual(sites.filter(\.isKey).map(\.id), ["baidu", "google", "claude"])
                t.expectEqual(FixtureLoader.legacySites.filter(\.inLightProbe).map(\.id), ["baidu", "google", "claude"])
                t.expectEqual(SiteCatalog.google.url.absoluteString, "https://www.google.com/generate_204")
                t.expectEqual(SiteCatalog.claude.url.absoluteString, "https://claude.ai/")
                let intranet = SiteCatalog.intranet(url: intranetURL)
                t.expect(intranet.isKey && intranet.inLightProbe)
                t.expectEqual(intranet.group, .intranet)
                t.expectNotContains(intranet.name, "corp.example")
            },
            TestCase("内网只在VPN 已连接且已配置时参与") { t in
                t.expectEqual(SiteCatalog.intranetDecision(intranetURL: nil, vpnState: .connected), .notConfigured)
                t.expectEqual(SiteCatalog.intranetDecision(intranetURL: nil, vpnState: .connected).skippedText, "未验证")
                t.expectEqual(SiteCatalog.intranetDecision(intranetURL: intranetURL, vpnState: .disconnected), .vpnDisconnected)
                t.expectEqual(SiteCatalog.intranetDecision(intranetURL: intranetURL, vpnState: .switching), .vpnUnconfirmed)
                t.expectEqual(SiteCatalog.intranetDecision(intranetURL: intranetURL, vpnState: .unconfirmed), .vpnUnconfirmed)
                let decision = SiteCatalog.intranetDecision(intranetURL: intranetURL, vpnState: .connected)
                t.expectEqual(decision.site?.url, intranetURL)
                t.expectEqual(SiteCatalog.lightProbeSites(intranet: decision).map(\.id), ["baidu", "google", "github", "intranet"])
                t.expectEqual(SiteCatalog.fullCheckSites(intranet: decision).count, 6)
                t.expectEqual(SiteCatalog.fullCheckSites(intranet: .vpnDisconnected).count, 5)
            },
            TestCase("配置站点决定轻测与完整检测，空清单不探测公开站点") { t in
                let custom = Site(id: "tokyo", name: "东京", group: .overseas,
                                  url: URL(string: "https://example.jp/")!, isKey: true, inLightProbe: true)
                var disabled = SiteCatalog.baidu
                disabled.isEnabled = false
                let sites = [disabled, custom, SiteCatalog.cloudflare]
                t.expectEqual(SiteCatalog.lightProbeSites(intranet: .notConfigured, sites: sites).map(\.id), ["tokyo"])
                t.expectEqual(SiteCatalog.fullCheckSites(intranet: .notConfigured, sites: sites).map(\.id), ["tokyo", "cloudflare"])
                t.expectEqual(SiteCatalog.lightProbeSites(intranet: .notConfigured, sites: []), [])
                t.expectEqual(SiteCatalog.fullCheckSites(intranet: .notConfigured, sites: []), [])
            },

            // MARK: 聚合

            TestCase("聚合：3 次中至少 2 次可达即为可达") { t in
                let site = SiteCatalog.github
                t.expectEqual(result(site, [.http(status: 200, latency: 0.1), .failure(.timeout), .http(status: 302, latency: 0.2)]).category, .reachable)
                t.expectEqual(result(site, [.http(status: 200, latency: 0.1), .failure(.timeout), .failure(.timeout)]).category, .timeout)
                t.expectEqual(result(site, [.http(status: 403, latency: 0.1), .http(status: 403, latency: 0.1), .http(status: 200, latency: 0.1)]).category, .restricted)
                t.expectEqual(result(site, [.failure(.dnsFailure), .failure(.dnsFailure), .failure(.timeout)]).category, .dnsFailure)
            },
            TestCase("聚合：取出现最多的类别，并列取最近一次") { t in
                let site = SiteCatalog.github
                t.expectEqual(result(site, [.failure(.timeout), .failure(.dnsFailure), .http(status: 200, latency: 0.1)]).category, .dnsFailure)
                t.expectEqual(result(site, [.failure(.tlsError), .http(status: 503, latency: 0.3), .failure(.tlsError)]).category, .tlsError)
            },
            TestCase("聚合：1 次与 2 次请求、没有请求") { t in
                let site = SiteCatalog.google
                t.expectEqual(result(site, [.http(status: 204, latency: 0.18)]).category, .reachable)
                t.expectEqual(result(site, [.failure(.connectionFailure)]).category, .connectionFailure)
                t.expectEqual(result(site, [.failure(.timeout), .http(status: 204, latency: 0.2)]).category, .reachable)
                t.expectEqual(result(site, []).category, .connectionFailure)
            },
            TestCase("延迟取收到 HTTP 响应的请求的中位数") { t in
                let site = SiteCatalog.baidu
                let three = result(site, [.http(status: 200, latency: 0.30), .http(status: 200, latency: 0.10), .http(status: 200, latency: 0.20)])
                t.expectEqual(three.medianLatency, 0.20)
                let withFailure = result(site, [.http(status: 200, latency: 0.10), .failure(.timeout), .http(status: 403, latency: 0.30)])
                t.expectEqual(withFailure.medianLatency, 0.20)
                t.expectNil(result(site, [.failure(.timeout)]).medianLatency)
                t.expectEqual(SiteAggregator.median([4, 1, 3, 2]), 2.5)
                t.expectNil(SiteAggregator.median([]))
                t.expectEqual(ok(site, 0.035).summaryText, "可达 35 ms")
                t.expectEqual(result(SiteCatalog.claude, [.http(status: 403, latency: 0.2)]).summaryText, "有响应（访问受限）")
            },

            // MARK: 连续失败与告警

            TestCase("4xx 不计失败") { t in
                var tracker = ConnectivityTracker()
                let restricted = result(SiteCatalog.claude, [.http(status: 403, latency: 0.2)])
                for _ in 0..<3 { tracker.recordRound([restricted], intranetEligible: false) }
                t.expectEqual(tracker.failureCount(for: "claude"), 0)
                t.expectEqual(tracker.faults, [])
            },
            TestCase("三轮门槛：两轮失败不告警，三轮才告警") { t in
                var tracker = ConnectivityTracker()
                tracker.recordRound([ok(SiteCatalog.baidu), fail(SiteCatalog.google), ok(SiteCatalog.claude)], intranetEligible: false)
                t.expectEqual(tracker.failureCount(for: "google"), 1)
                t.expectEqual(tracker.faults, [])
                tracker.recordRound([ok(SiteCatalog.baidu), fail(SiteCatalog.google, .dnsFailure), ok(SiteCatalog.claude)], intranetEligible: false)
                t.expectEqual(tracker.failureCount(for: "google"), 2)
                t.expectEqual(tracker.faults, [])
                tracker.recordRound([ok(SiteCatalog.baidu), fail(SiteCatalog.google, .timeout), ok(SiteCatalog.claude)], intranetEligible: false)
                t.expectEqual(tracker.faults.map(\.key), [.site("google")])
                t.expectEqual(tracker.faults.first?.severity, .warning)
                t.expectEqual(tracker.faults.first?.message, "Google 连续三轮访问失败")
            },
            TestCase("中间成功一轮会清零") { t in
                var tracker = ConnectivityTracker()
                tracker.recordRound([fail(SiteCatalog.google)], intranetEligible: false)
                tracker.recordRound([ok(SiteCatalog.google)], intranetEligible: false)
                tracker.recordRound([fail(SiteCatalog.google)], intranetEligible: false)
                t.expectEqual(tracker.failureCount(for: "google"), 1)
                t.expectEqual(tracker.faults, [])
            },
            TestCase("大陆组：百度连续三轮失败为红") { t in
                var tracker = ConnectivityTracker()
                for _ in 0..<3 { tracker.recordRound([fail(SiteCatalog.baidu, .connectionFailure)], intranetEligible: false) }
                t.expectEqual(tracker.faults.map(\.key), [.group(.mainland)])
                t.expectEqual(tracker.faults.first?.severity, .critical)
                t.expectEqual(tracker.faults.first?.key.rawValue, "group.mainland")
            },
            TestCase("改名或改 URL 的百度按当前站点生成动态告警") { t in
                var renamed = SiteCatalog.baidu
                renamed.name = "自选大陆站点"
                let renamedFaults = ConnectivityTracker.faults(
                    failingSiteIDs: [renamed.id], context: .consecutiveRounds, sites: [renamed])
                t.expectEqual(renamedFaults.map(\.key), [.site(renamed.id), .group(.mainland)])
                t.expectContains(renamedFaults.last?.message ?? "", "自选大陆站点")
                t.expectNotContains(renamedFaults.last?.message ?? "", "百度")

                var changedURL = SiteCatalog.baidu
                changedURL.url = URL(string: "https://example.cn/health")!
                let changedURLFaults = ConnectivityTracker.faults(
                    failingSiteIDs: [changedURL.id], context: .consecutiveRounds, sites: [changedURL])
                t.expectEqual(changedURLFaults.map(\.key), [.site(changedURL.id), .group(.mainland)])
            },
            TestCase("海外组：单站失败为黄，双站失败为红") { t in
                var single = ConnectivityTracker()
                for _ in 0..<3 { single.recordRound([fail(SiteCatalog.github, .tlsError), ok(SiteCatalog.google)], intranetEligible: false) }
                t.expectEqual(single.faults.map(\.key), [.site("github")])
                t.expectEqual(Severity.worst(single.faults.map(\.severity)), .warning)

                var both = ConnectivityTracker()
                for _ in 0..<3 { both.recordRound([fail(SiteCatalog.github), fail(SiteCatalog.google, .serverError)], intranetEligible: false) }
                t.expectEqual(both.faults.map(\.key), [.site("google"), .site("github"), .group(.overseas)])
                t.expectEqual(both.faults.last?.severity, .critical)
                t.expectEqual(FaultKey.group(.overseas).rawValue, "group.overseas")
            },
            TestCase("海外非关键站点不告警") { t in
                var tracker = ConnectivityTracker()
                let round = [fail(SiteCatalog.yahooJapan), fail(SiteCatalog.sony), fail(SiteCatalog.cloudflare), fail(SiteCatalog.bilibili)]
                for _ in 0..<5 { tracker.recordRound(round, intranetEligible: false) }
                t.expectEqual(tracker.faults, [])
                t.expectEqual(tracker.consecutiveFailures, [:])
            },
            TestCase("自定义关键站点按当前启用清单判定单站与整组故障") { t in
                let tokyo = Site(id: "tokyo", name: "东京", group: SiteGroup(rawValue: "东亚"),
                                 url: URL(string: "https://tokyo.example/")!, isKey: true, inLightProbe: true)
                let osaka = Site(id: "osaka", name: "大阪", group: SiteGroup(rawValue: "东亚"),
                                 url: URL(string: "https://osaka.example/")!, isKey: true, inLightProbe: true)
                var tracker = ConnectivityTracker()
                for _ in 0..<3 { tracker.recordRound([fail(tokyo), ok(osaka)], intranetEligible: false) }
                t.expectEqual(tracker.faults(sites: [tokyo, osaka]).map(\.key), [.site("tokyo")])
                for _ in 0..<3 { tracker.recordRound([fail(tokyo), fail(osaka)], intranetEligible: false) }
                t.expectEqual(tracker.faults(sites: [tokyo, osaka]).map(\.key),
                              [.site("tokyo"), .site("osaka"), .group(SiteGroup(rawValue: "东亚"))])
                t.expectEqual(tracker.faults(sites: [tokyo, osaka]).last?.severity, .critical)
                t.expectContains(tracker.faults(sites: [tokyo, osaka]).last?.message ?? "", "东亚访问故障")
                var disabled = tokyo
                disabled.isEnabled = false
                t.expectEqual(tracker.faults(sites: [disabled]).map(\.key), [])
                t.expectEqual(tracker.faults(sites: []), [])
            },
            TestCase("禁用内置关键站点的历史失败不产生故障") { t in
                var tracker = ConnectivityTracker()
                for _ in 0..<3 { tracker.recordRound([fail(SiteCatalog.google)], intranetEligible: false) }
                var disabled = SiteCatalog.google
                disabled.isEnabled = false
                t.expectEqual(tracker.faults(sites: [disabled, SiteCatalog.claude]), [])
            },
            TestCase("完整检测中关键站点的汇总结果计为一轮") { t in
                var tracker = ConnectivityTracker()
                let full = FixtureLoader.legacySites.map { site -> SiteResult in
                    site.id == "baidu"
                        ? result(site, [.failure(.timeout), .failure(.timeout), .http(status: 200, latency: 0.1)])
                        : result(site, [.http(status: 200, latency: 0.1), .http(status: 200, latency: 0.1), .http(status: 200, latency: 0.1)])
                }
                tracker.recordRound(full, intranetEligible: false)
                t.expectEqual(tracker.failureCount(for: "baidu"), 1)
                tracker.recordRound([fail(SiteCatalog.baidu)], intranetEligible: false)
                t.expectEqual(tracker.faults, [])
                tracker.recordRound([fail(SiteCatalog.baidu)], intranetEligible: false)
                t.expectEqual(tracker.faults.map(\.key), [.group(.mainland)])
            },
            TestCase("内网站点：连接时连续三轮失败为黄，断开时不计") { t in
                let intranet = SiteCatalog.intranet(url: intranetURL)
                var tracker = ConnectivityTracker()
                for _ in 0..<3 { tracker.recordRound([fail(intranet)], intranetEligible: true) }
                t.expectEqual(tracker.faults.map(\.key), [.site("intranet")])
                t.expectEqual(tracker.faults.first?.severity, .warning)
                t.expectNotContains(tracker.faults.first?.message ?? "", "corp.example")

                // VPN 断开：清零且不再计入。
                tracker.recordRound([fail(intranet)], intranetEligible: false)
                t.expectEqual(tracker.failureCount(for: "intranet"), 0)
                t.expectEqual(tracker.faults, [])
            },
            TestCase("reset 清零全部计数") { t in
                var tracker = ConnectivityTracker()
                for _ in 0..<3 { tracker.recordRound([fail(SiteCatalog.baidu), fail(SiteCatalog.google)], intranetEligible: false) }
                t.expect(!tracker.faults.isEmpty)
                tracker.reset()
                t.expectEqual(tracker.faults, [])
                t.expectEqual(tracker.failureCount(for: "baidu"), 0)
                tracker.recordRound([fail(SiteCatalog.baidu)], intranetEligible: false)
                t.expectEqual(tracker.faults, [], "重置后需重新累计三轮")
            },

            // MARK: 历史

            TestCase("每站保留最近 5 次结果") { t in
                var history = SiteHistory()
                let categories: [ProbeCategory] = [.timeout, .reachable, .reachable, .dnsFailure, .reachable, .restricted, .reachable]
                for category in categories {
                    history.record(category == .reachable ? ok(SiteCatalog.google) : fail(SiteCatalog.google, category))
                }
                history.record(ok(SiteCatalog.baidu))
                t.expectEqual(history.recent(for: "google").map(\.category), [.reachable, .dnsFailure, .reachable, .restricted, .reachable])
                t.expectEqual(history.latest(for: "google")?.category, .reachable)
                t.expectEqual(history.recent(for: "baidu").count, 1)
                t.expectEqual(history.recent(for: "claude"), [])
                history.clear()
                t.expectEqual(history.recent(for: "google"), [])
            },
        ])
    }
}
