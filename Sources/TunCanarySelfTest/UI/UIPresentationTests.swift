import Foundation
import TunCanaryCore
import TunCanaryUI

/// 弹窗格式化逻辑：状态文字、时间、延迟、最近 5 次结果、错误原因、内网决策与恢复命令。
enum UIPresentationTests {
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    /// 2026-09-26 12:00:00 UTC = 20:00:00 上海。
    static let now = Date(timeIntervalSince1970: 1_790_424_000)

    static func result(_ site: Site, _ outcomes: [RequestOutcome], at offset: TimeInterval = 0) -> SiteResult {
        SiteAggregator.aggregate(site: site, outcomes: outcomes, checkedAt: now.addingTimeInterval(offset))
    }

    static func ok(_ ms: Double) -> RequestOutcome { .http(status: 200, latency: ms / 1000) }

    static func greenLocal() -> LocalAssessment {
        let cards = [
            StatusCard(kind: .proxyDNS, title: "Mihomo DNS", severity: .ok, conclusion: "7874 端口响应 8 ms"),
            StatusCard(kind: .proxyTun, title: "Clash TUN", severity: .ok, conclusion: "配置开启，utun1024 存在"),
            StatusCard(kind: .primaryDNS, title: "Wi-Fi DNS", label: "主网络 DNS（Wi-Fi）", severity: .ok,
                       conclusion: "DNS 为 119.29.29.29，符合预期"),
            StatusCard(kind: .vpn, title: "Example VPN", severity: .ok, conclusion: "已断开"),
        ]
        return LocalAssessment(
            severity: .ok, cards: cards, faults: [], primaryReason: "各项检查正常",
            tunState: .running(interface: "utun1024"), vpnState: .disconnected, isInGracePeriod: false,
            intranetProbeEnabled: false, primaryServiceName: "Wi-Fi", mihomoDNSPort: 7874,
            diagnosticNotes: [], evaluatedAt: now)
    }

    static var suite: TestSuite {
        TestSuite("UI.Presentation", [
            TestCase("色调映射：严重程度与探测类别") { t in
                t.expectEqual(Severity.allCases.map(StatusTone.init), [.ok, .neutral, .warning, .critical])
                t.expectEqual(StatusTone(ProbeCategory.reachable), .ok)
                t.expectEqual(StatusTone(ProbeCategory.restricted), .info, "4xx 不计失败，不用红色")
                for category in ProbeCategory.allCases where category.countsAsFailure {
                    t.expectEqual(StatusTone(category), .critical, category.rawValue)
                }
            },
            TestCase("顶部：状态文字、原因与最近检查时间") { t in
                let overall = OverallAssessment(local: greenLocal(), connectivityFaults: [])
                let header = PopoverFormatter.header(overall: overall, lastCheckedAt: now.addingTimeInterval(-5),
                                                     graceEndsAt: nil, isChecking: false, now: now, timeZone: shanghai)
                t.expectEqual(header.statusText, "正常")
                t.expectEqual(header.tone, .ok)
                t.expectEqual(header.reason, "各项检查正常")
                t.expectEqual(header.checkedText, "最近检查 19:59:55")
                t.expectNil(header.graceText)
                t.expectNil(header.hint)

                let google = OverallAssessment(
                    local: greenLocal(),
                    connectivityFaults: ConnectivityTracker.faults(failingSiteIDs: ["google"], context: .consecutiveRounds))
                let warning = PopoverFormatter.header(overall: google, lastCheckedAt: now, graceEndsAt: nil,
                                                      isChecking: true, now: now, timeZone: shanghai)
                t.expectEqual(warning.statusText, "需关注")
                t.expectEqual(warning.tone, .warning)
                t.expectEqual(warning.reason, "Google 连续两轮访问失败")
            },
            TestCase("顶部：首次启动与首次检查中") { t in
                let none = OverallAssessment(local: nil, connectivityFaults: [])
                let idle = PopoverFormatter.header(overall: none, lastCheckedAt: nil, graceEndsAt: nil,
                                                   isChecking: false, now: now, timeZone: shanghai)
                t.expectEqual(idle.statusText, "未确认")
                t.expectEqual(idle.tone, .neutral)
                t.expectEqual(idle.reason, "尚无检查结果")
                t.expectEqual(idle.checkedText, "尚未完成检查")
                let checking = PopoverFormatter.header(overall: none, lastCheckedAt: nil, graceEndsAt: nil,
                                                       isChecking: true, now: now, timeZone: shanghai)
                t.expectEqual(checking.checkedText, "正在进行首次检查…")
            },
            TestCase("顶部：宽限期显示“切换中”与复查时间") { t in
                var local = greenLocal()
                local.isInGracePeriod = true
                local.vpnState = .switching
                local.cards[3].severity = .unknown
                local.cards[3].conclusion = "切换中"
                local.severity = .unknown
                let overall = OverallAssessment(local: local, connectivityFaults: [])
                let header = PopoverFormatter.header(overall: overall, lastCheckedAt: now, graceEndsAt: now.addingTimeInterval(8),
                                                     isChecking: false, now: now, timeZone: shanghai)
                t.expectEqual(header.statusText, "切换中")
                t.expectEqual(header.tone, .neutral)
                t.expectEqual(header.reason, "网络切换中")
                t.expectEqual(header.graceText, "网络切换中，20:00:08 后自动复查")
            },
            TestCase("时间格式：当天只显示时刻，跨天带日期") { t in
                t.expectEqual(PopoverFormatter.clockText(now, now: now, timeZone: shanghai), "20:00:00")
                t.expectEqual(PopoverFormatter.clockText(now.addingTimeInterval(-86_400), now: now, timeZone: shanghai),
                              "9月25日 20:00")
                // 时区按注入值计算“当天”：UTC 12:00 与上海 20:00 同一天。
                let utc = TimeZone(identifier: "UTC")!
                t.expectEqual(PopoverFormatter.clockText(now, now: now, timeZone: utc), "12:00:00")
            },
            TestCase("延迟：显示中位数，没有响应时为占位") { t in
                let reachable = result(SiteCatalog.baidu, [ok(35.4), ok(80), ok(12)])
                t.expectEqual(PopoverFormatter.latencyText(reachable), "35 ms")
                let restricted = result(SiteCatalog.claude, [.http(status: 403, latency: 0.2361)])
                t.expectEqual(PopoverFormatter.latencyText(restricted), "236 ms")
                let timeout = result(SiteCatalog.google, [.failure(.timeout)])
                t.expectEqual(PopoverFormatter.latencyText(timeout), "—")
                t.expectEqual(PopoverFormatter.latencyText(nil), "—")
            },
            TestCase("最近 5 次：旧到新，不足补空位，超过取最后 5 次") { t in
                t.expectEqual(PopoverFormatter.historyMarks([]), Array(repeating: .empty, count: 5))
                let two = [result(SiteCatalog.google, [ok(180)]), result(SiteCatalog.google, [.failure(.timeout)])]
                t.expectEqual(PopoverFormatter.historyMarks(two).map(\.category),
                              [nil, nil, nil, .reachable, .timeout])
                t.expectEqual(PopoverFormatter.historyMarks(two).map(\.tone), [.neutral, .neutral, .neutral, .ok, .critical])
                t.expectEqual(PopoverFormatter.historyMarks(two).map(\.label), ["无", "无", "无", "可达", "超时"])
                let categories: [ProbeCategory] = [.dnsFailure, .reachable, .restricted, .tlsError, .serverError, .connectionFailure, .reachable]
                let seven = categories.map { category -> SiteResult in
                    category == .reachable || category == .restricted || category == .serverError
                        ? result(SiteCatalog.google, [.http(status: category == .reachable ? 204 : category == .restricted ? 403 : 503, latency: 0.1)])
                        : result(SiteCatalog.google, [.failure(category)])
                }
                t.expectEqual(PopoverFormatter.historyMarks(seven).map(\.category),
                              [.restricted, .tlsError, .serverError, .connectionFailure, .reachable])
                t.expectEqual(PopoverFormatter.historyMarks(seven).map(\.tone), [.info, .critical, .critical, .critical, .ok])
            },
            TestCase("错误原因：状态码、连续失败与多次请求分布") { t in
                let redactor = Redactor()
                let restricted = [result(SiteCatalog.chatgpt, [.http(status: 403, latency: 0.2), .http(status: 403, latency: 0.2),
                                                              .http(status: 429, latency: 0.3)])]
                t.expectEqual(PopoverFormatter.errorDetail(restricted, redactor: redactor), "HTTP 403 / 429")

                let failing = [
                    result(SiteCatalog.google, [ok(180)]),
                    result(SiteCatalog.google, [.failure(.timeout)]),
                    result(SiteCatalog.google, [.failure(.timeout)]),
                ]
                t.expectEqual(PopoverFormatter.trailingFailures(failing), 2)
                t.expectEqual(PopoverFormatter.errorDetail(failing, redactor: redactor), "连续 2 次失败")

                let mixed = [result(SiteCatalog.github, [.failure(.timeout), .failure(.timeout), ok(200)])]
                t.expectEqual(PopoverFormatter.errorDetail(mixed, redactor: redactor), "3 次请求：超时 ×2、可达 ×1")

                let reachable = [result(SiteCatalog.baidu, [ok(30), ok(31), .failure(.timeout)])]
                t.expectNil(PopoverFormatter.errorDetail(reachable, redactor: redactor), "可达时不显示错误原因")

                let url = URL(string: "https://intranet.corp.example/health")!
                let intranet = SiteCatalog.intranet(url: url)
                let single = [result(intranet, [.failure(.dnsFailure, detail: "无法解析 intranet.corp.example")])]
                let detail = try t.require(PopoverFormatter.errorDetail(single, redactor: Redactor(intranetURL: url)))
                t.expectNotContains(detail, "intranet.corp.example")
                t.expectContains(detail, "[内网站点]")
            },
            TestCase("站点行：类别文字、延迟、历史与朗读文本") { t in
                let untested = PopoverFormatter.siteRow(site: SiteCatalog.sony, history: [])
                t.expectEqual(untested.statusText, "尚未检测")
                t.expectEqual(untested.tone, .neutral)
                t.expectEqual(untested.latencyText, "—")
                t.expect(!untested.isKey)

                let baidu = PopoverFormatter.siteRow(site: SiteCatalog.baidu, history: [result(SiteCatalog.baidu, [ok(35)])])
                t.expectEqual(baidu.statusText, "可达")
                t.expectEqual(baidu.tone, .ok)
                t.expectEqual(baidu.latencyText, "35 ms")
                t.expect(baidu.isKey)
                t.expectEqual(baidu.accessibilityText, "百度：可达，延迟 35 ms，最近 1 次：可达")

                let claude = PopoverFormatter.siteRow(site: SiteCatalog.claude,
                                                      history: [result(SiteCatalog.claude, [.http(status: 403, latency: 0.24)])])
                t.expectEqual(claude.statusText, "有响应（访问受限）")
                t.expectEqual(claude.tone, .info)
                t.expectEqual(claude.detailText, "HTTP 403")
            },
            TestCase("内网站点按决策显示，不出现 URL") { t in
                let url = URL(string: "https://intranet.corp.example/health")!
                func intranetRow(_ decision: IntranetProbeDecision, history: SiteHistory = SiteHistory()) -> SiteRowPresentation? {
                    PopoverFormatter.siteGroups(history: history, intranet: decision, redactor: Redactor(intranetURL: url))
                        .first { $0.group == .intranet }?.rows.first
                }
                let notConfigured = try t.require(intranetRow(.notConfigured))
                t.expectEqual(notConfigured.statusText, "未验证")
                t.expectEqual(notConfigured.detailText, "未配置内网站点 URL，可在设置中填写")
                t.expectEqual(notConfigured.tone, .neutral)
                t.expectContains(notConfigured.accessibilityText, "未配置内网站点 URL")
                t.expectEqual(try t.require(intranetRow(.vpnDisconnected)).statusText, "未连接 VPN")
                t.expectEqual(try t.require(intranetRow(.vpnUnconfirmed)).statusText, "VPN 状态未确认")

                let site = SiteCatalog.intranet(url: url)
                var history = SiteHistory()
                history.record(result(site, [ok(28)]))
                let probed = try t.require(intranetRow(.probe(site), history: history))
                t.expectEqual(probed.name, "内网站点")
                t.expectEqual(probed.statusText, "可达")
                t.expectEqual(probed.latencyText, "28 ms")
                for row in [notConfigured, probed] {
                    t.expectNotContains(row.accessibilityText, "intranet.corp.example")
                    t.expectNotContains(row.name, "intranet")
                }
            },
            TestCase("站点分组：顺序与每组站点") { t in
                let groups = PopoverFormatter.siteGroups(history: SiteHistory(), intranet: .notConfigured)
                t.expectEqual(groups.map(\.title), ["国内", "海外", "内网站点"])
                t.expectEqual(groups.map { $0.rows.map(\.name) }, [
                    ["百度", "哔哩哔哩"],
                    ["Google", "GitHub", "Cloudflare"],
                    ["内网站点"],
                ])
                t.expectEqual(groups.flatMap(\.rows).filter(\.isKey).map(\.id), ["baidu", "google", "github", "intranet"])
            },
            TestCase("站点分组：自定义公开清单与空清单") { t in
                let custom = Site(id: "custom", name: "自定义", group: SiteGroup(rawValue: "东亚"),
                                  url: URL(string: "https://custom.example.test/")!,
                                  isKey: true, inLightProbe: true)
                let groups = PopoverFormatter.siteGroups(history: SiteHistory(), intranet: .notConfigured,
                                                         sites: [custom])
                t.expectEqual(groups.map(\.title), ["东亚", "内网站点"])
                t.expectEqual(groups.map { $0.rows.map(\.id) }, [["custom"], [SiteCatalog.intranetID]])
                let empty = PopoverFormatter.siteGroups(history: SiteHistory(), intranet: .notConfigured, sites: [])
                t.expectEqual(empty.map(\.group), [.intranet])
                t.expectEqual(empty[0].rows.map(\.id), [SiteCatalog.intranetID])
            },
            TestCase("状态卡：按弹窗顺序排列，首次启动为灰色占位") { t in
                t.expectEqual(PopoverFormatter.cards(greenLocal()).map(\.kind), [.proxyTun, .vpn, .primaryDNS, .proxyDNS])
                let placeholders = PopoverFormatter.cards(nil)
                t.expectEqual(placeholders.map(\.title), ["Clash TUN", "VPN", "主网络 DNS", "Mihomo DNS"])
                t.expect(placeholders.allSatisfy { $0.severity == .unknown && $0.conclusion == "尚未检查" })
            },
            TestCase("进度文字与“立即复测”按钮") { t in
                t.expectEqual(PopoverFormatter.recheckTitle(nil), "立即复测")
                t.expectEqual(PopoverFormatter.recheckTitle(CheckProgress(kind: .full, completed: 4, total: 9)), "复测中 4/9")
                t.expectEqual(PopoverFormatter.recheckTitle(CheckProgress(kind: .full)), "复测中…")
                t.expectEqual(PopoverFormatter.recheckTitle(CheckProgress(kind: .light, completed: 1, total: 3)), "检查中…")
                t.expectEqual(PopoverFormatter.progressText(CheckProgress(kind: .full, completed: 4, total: 9)), "完整检测 4/9")
                t.expectEqual(PopoverFormatter.progressText(CheckProgress(kind: .light, completed: 1, total: 3)), "轻测 1/3")
                t.expectEqual(PopoverFormatter.progressText(CheckProgress(kind: .local)), "本机检查中…")
                t.expectEqual(CheckProgress(kind: .full, completed: 4, total: 8).fraction, 0.5)
                t.expectNil(CheckProgress(kind: .local).fraction)
                t.expectEqual(CheckProgress(kind: .full, completed: 12, total: 8).fraction, 1)
            },
            TestCase("菜单栏图标状态：检查中保留上次的颜色") { t in
                let overall = OverallAssessment(
                    local: greenLocal(),
                    connectivityFaults: ConnectivityTracker.faults(failingSiteIDs: ["google"], context: .consecutiveRounds))
                let checking = MenuBarIconState(overall: overall, isChecking: true)
                t.expectEqual(checking.severity, .warning)
                t.expect(checking.isChecking)
                t.expectEqual(checking.tooltip, "TunCanary：需关注 — Google 连续两轮访问失败")
                t.expectEqual(checking.accessibilityLabel, "TunCanary：需关注，检查进行中")
                let first = MenuBarIconState(overall: OverallAssessment(local: nil, connectivityFaults: []), isChecking: false)
                t.expectEqual(first.severity, .unknown)
                t.expectEqual(first.tooltip, "TunCanary：未确认 — 尚无检查结果")
                t.expectEqual(first.accessibilityLabel, "TunCanary：未确认")
            },
            TestCase("恢复步骤：取出可复制的命令") { t in
                let steps = RecoveryGuide.steps(serviceName: "Wi-Fi")
                t.expectEqual(steps.compactMap(PopoverFormatter.command(in:)), ["networksetup -getdnsservers Wi-Fi"])
                let wired = RecoveryGuide.steps(serviceName: "USB 10/100/1000 LAN")
                t.expectEqual(PopoverFormatter.command(in: wired[2]), "networksetup -getdnsservers \"USB 10/100/1000 LAN\"")
                t.expectNil(PopoverFormatter.command(in: steps[0]))
            },
        ])
    }
}
