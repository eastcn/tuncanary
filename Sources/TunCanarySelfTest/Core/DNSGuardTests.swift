import Foundation
import TunCanaryCore

/// DNS 守护进程：文件解析、卡片中的摘要，以及与判定、命令行输出的关系。全部使用合成数据。
enum DNSGuardTests {
    static let now = Date(timeIntervalSince1970: 1_790_424_000)
    static let utc = TimeZone(identifier: "UTC")!
    static let target = ["192.0.2.53"]

    static func installed(target: [String] = target, takeover: Bool = false, state: DNSGuardState? = nil,
                          events: [DNSGuardEvent] = []) -> Collected<DNSGuardSnapshot> {
        .collected(DNSGuardSnapshot(
            installed: true,
            config: .collected(DNSGuardConfigSummary(targetDNS: target, connectedTakeoverEnabled: takeover)),
            state: state.map { .collected($0) } ?? .notCollected,
            recentEvents: events))
    }

    static var suite: TestSuite {
        TestSuite("Core.DNSGuard", [
            TestCase("路径：全部位于系统目录，测试可替换根目录") { t in
                let paths = DNSGuardPaths()
                t.expectEqual(paths.stateFile, "/Library/Application Support/TunCanary/dns-guard-state.json")
                t.expectEqual(paths.eventLogFile, "/Library/Application Support/TunCanary/dns-guard-events.jsonl")
                t.expectEqual(paths.configFile, "/Library/Application Support/TunCanary/dns-guard.json")
                t.expectEqual(paths.launchDaemonFile,
                              "/Library/LaunchDaemons/io.github.eastcn.tuncanary.dns-guard.plist")
                t.expectEqual(DNSGuardPaths(root: "/tmp/x/").configFile,
                              "/tmp/x/Library/Application Support/TunCanary/dns-guard.json")
            },
            TestCase("配置：只取目标 DNS 与连接期开关，缺少目标值时报错") { t in
                let json = """
                {"targetDNS":[" 192.0.2.53 ",""],"allowedServiceTypes":["IEEE80211"],
                 "connectedTakeover":{"enabled":true,"maxWritesPerTenMinutes":3},"sampleDelaySeconds":3}
                """
                let config = try DNSGuardFileParser.parseConfig(Data(json.utf8))
                t.expectEqual(config, DNSGuardConfigSummary(targetDNS: ["192.0.2.53"], connectedTakeoverEnabled: true))
                let minimal = try DNSGuardFileParser.parseConfig(Data(#"{"targetDNS":["192.0.2.53"]}"#.utf8))
                t.expect(!minimal.connectedTakeoverEnabled)
                t.expectThrows(try DNSGuardFileParser.parseConfig(Data(#"{"targetDNS":[]}"#.utf8)))
                t.expectThrows(try DNSGuardFileParser.parseConfig(Data("not json".utf8)))
            },
            TestCase("状态文件：往返一致，缺少的字段取默认值") { t in
                let run = DNSGuardEvent(date: now, phase: .disconnected, outcome: .written)
                let state = DNSGuardState(lastRun: run, lastWrite: run, consecutiveFailures: 1,
                                          backoffUntil: now.addingTimeInterval(600), connectedTakeoverSuspended: true)
                let data = try DNSGuardFileParser.encoder().encode(state)
                t.expectEqual(try DNSGuardFileParser.parseState(data), state)
                t.expectEqual(try DNSGuardFileParser.parseState(Data("{}".utf8)), DNSGuardState())
                let text = #"{"lastRun":{"date":"2026-09-26T12:00:00Z","outcome":"skipped","reason":"TUN 未运行"}}"#
                t.expectEqual(try DNSGuardFileParser.parseState(Data(text.utf8)).lastRun,
                              DNSGuardEvent(date: now, outcome: .skipped, reason: "TUN 未运行"))
                t.expectThrows(try DNSGuardFileParser.parseState(Data("[]".utf8)))
            },
            TestCase("事件日志：跳过无法解码的行，只保留最后几条") { t in
                let lines = [
                    #"{"date":"2026-09-26T12:00:00Z","outcome":"skipped","reason":"TUN 未运行"}"#,
                    "not json",
                    #"{"date":"2026-09-26T12:00:30Z","phase":"disconnected","outcome":"written"}"#,
                    #"{"date":"2026-09-26T12:01:00Z","phase":"disconnected","outcome":"bogus"}"#,
                    #"{"date":"2026-09-26T12:01:30Z","phase":"disconnected","outcome":"compliant"}"#,
                ]
                let data = Data(lines.joined(separator: "\n").utf8)
                let events = DNSGuardFileParser.parseEvents(data, limit: 2)
                t.expectEqual(events.map(\.outcome), [.written, .compliant])
                t.expectEqual(DNSGuardFileParser.parseEvents(data, limit: 10).count, 3)
                t.expectEqual(events[0].text, "断开期：写入并读回成功")
                t.expectEqual(DNSGuardEvent(date: now, outcome: .skipped, reason: "TUN 未运行").text, "跳过（TUN 未运行）")
            },
            TestCase("摘要：未采集为 nil，未安装与读取失败分开表示") { t in
                let settings = AppSettings(expectedDNS: target)
                t.expectNil(DNSGuardSummary.make(.notCollected, settings: settings, now: now))
                let absent = try t.require(DNSGuardSummary.make(.collected(.notInstalled), settings: settings, now: now))
                t.expect(!absent.installed)
                t.expectEqual(absent.statusText, "DNS 守护进程：未安装")
                t.expectEqual(absent.lines(), ["DNS 守护进程：未安装"])
                let failed = try t.require(DNSGuardSummary.make(.failed(reason: "权限不足"), settings: settings, now: now))
                t.expectEqual(failed.statusText, "DNS 守护进程：状态未知（权限不足）")
            },
            TestCase("摘要：最近一次与最近写入，相同时只显示一次") { t in
                let settings = AppSettings(expectedDNS: target)
                let never = try t.require(DNSGuardSummary.make(installed(), settings: settings, now: now))
                t.expectEqual(never.lines(timeZone: utc), ["DNS 守护进程：已安装", "最近一次：尚未运行"])
                t.expectEqual(never.lastRunSeverity, .unknown)

                let written = DNSGuardEvent(date: now.addingTimeInterval(-60), phase: .disconnected, outcome: .written)
                let same = try t.require(DNSGuardSummary.make(
                    installed(state: DNSGuardState(lastRun: written, lastWrite: written)), settings: settings, now: now))
                t.expectNil(same.lastWrite)
                t.expectEqual(same.lastRunSeverity, .ok)
                t.expectEqual(same.lastRunText(timeZone: utc), "最近一次（2026-09-26 11:59:00）：断开期：写入并读回成功")

                let skipped = DNSGuardEvent(date: now, outcome: .skipped, reason: "TUN 未运行")
                let later = try t.require(DNSGuardSummary.make(
                    installed(state: DNSGuardState(lastRun: skipped, lastWrite: written)), settings: settings, now: now))
                t.expectEqual(later.lines(timeZone: utc), [
                    "DNS 守护进程：已安装",
                    "最近一次（2026-09-26 12:00:00）：跳过（TUN 未运行）",
                    "最近写入（2026-09-26 11:59:00）：断开期：写入并读回成功",
                ])
                t.expectEqual(later.lastRunSeverity, .unknown)
                t.expectEqual(DNSGuardOutcome.verifyFailed.severity, .warning)
            },
            TestCase("摘要：目标值与预期 DNS 不一致、规则不匹配时提示") { t in
                func notices(_ settings: AppSettings, target: [String] = target, takeover: Bool = false) throws -> [String] {
                    try t.require(DNSGuardSummary.make(installed(target: target, takeover: takeover),
                                                       settings: settings, now: now)).notices
                }
                t.expectEqual(try notices(AppSettings(expectedDNS: ["192.0.2.53"])), [])
                t.expectEqual(try notices(AppSettings(expectedDNS: ["192.0.2.54", "192.0.2.53"]),
                                          target: ["192.0.2.53", "192.0.2.54"]), [], "忽略顺序")
                t.expectEqual(try notices(AppSettings(expectedDNS: ["192.0.2.54"])),
                              ["守护进程的目标 DNS 为 192.0.2.53，与设置中的预期 DNS 192.0.2.54 不一致"])
                t.expectEqual(try notices(AppSettings(disconnectedDNSRule: .empty)),
                              ["守护进程会把 DNS 设为 192.0.2.53，建议把“VPN 断开、TUN 运行时”设为“指定地址”"])
                t.expectEqual(try notices(AppSettings(expectedDNS: target), takeover: true),
                              ["守护进程已启用连接期接管，建议把“VPN 连接时”设为“由代理接管（与断开时相同）”"])
                t.expectEqual(try notices(AppSettings(expectedDNS: target, connectedDNSRule: .proxyTakeover),
                                          takeover: true), [])
                t.expectEqual(try notices(AppSettings(expectedDNS: target, connectedDNSRule: .proxyTakeover)),
                              ["守护进程未启用连接期接管，VPN 连接期间不会改写 DNS"])
            },
            TestCase("摘要：配置不可读、退避和停用连接期接管") { t in
                let settings = AppSettings(expectedDNS: target)
                let broken = DNSGuardSnapshot(installed: true, config: .failed(reason: "权限不足"),
                                              state: .failed(reason: "状态文件不是有效的 JSON"))
                t.expectEqual(try t.require(DNSGuardSummary.make(.collected(broken), settings: settings, now: now)).notices, [
                    "无法读取守护进程配置：权限不足",
                    "无法读取守护进程状态：状态文件不是有效的 JSON",
                ])
                let missing = DNSGuardSnapshot(installed: true)
                t.expectEqual(try t.require(DNSGuardSummary.make(.collected(missing), settings: settings, now: now)).notices,
                              ["未找到守护进程配置"])

                let state = DNSGuardState(consecutiveFailures: 3, backoffUntil: now.addingTimeInterval(300),
                                          connectedTakeoverSuspended: true)
                let summary = try t.require(DNSGuardSummary.make(installed(state: state), settings: settings, now: now,
                                                                 timeZone: utc))
                t.expectEqual(summary.notices, [
                    "连接期接管已停用：写入过于频繁，VPN 客户端可能在反复改写 DNS。VPN 下次断开后恢复",
                    "连续失败 3 次，2026-09-26 12:05:00 前不再写入",
                ])
                let expired = try t.require(DNSGuardSummary.make(installed(state: state), settings: settings,
                                                                 now: now.addingTimeInterval(301)))
                t.expectEqual(expired.notices.count, 1, "退避结束后不再提示")
            },
            TestCase("判定：守护进程只附在主网络 DNS 卡，不改变严重程度和故障键") { t in
                let settings = AppSettings(expectedDNS: ["192.0.2.53"])
                var snapshot = DNSRuleTests.snapshot(saved: [])
                let failure = DNSGuardEvent(date: now, phase: .disconnected, outcome: .verifyFailed)
                snapshot.dnsGuard = installed(state: DNSGuardState(lastRun: failure, lastWrite: failure,
                                                                   consecutiveFailures: 1))
                let result = DNSRuleTests.evaluate(snapshot, settings)
                let dns = try t.require(result.card(.primaryDNS))
                t.expectEqual(dns.severity, .critical, "卡片严重程度只来自 TunCanary 的检测")
                t.expectEqual(result.faultKeys, [.dnsNotRestored])
                t.expectEqual(dns.dnsGuard?.lastRun, failure)
                t.expectEqual(dns.dnsGuard?.lastRunSeverity, .warning)
                t.expect(result.cards.filter { $0.kind != .primaryDNS }.allSatisfy { $0.dnsGuard == nil })

                var healthy = DNSRuleTests.snapshot(saved: ["192.0.2.53"])
                healthy.dnsGuard = snapshot.dnsGuard
                let ok = DNSRuleTests.evaluate(healthy, settings)
                t.expectEqual(ok.severity, .ok, "守护进程失败不让卡片变黄")
                t.expectEqual(ok.faultKeys, [])

                let grace = LocalEvaluator(paths: VPNTests.paths)
                    .evaluate(snapshot: snapshot, settings: settings, inGracePeriod: true)
                t.expectEqual(grace.card(.primaryDNS)?.dnsGuard?.lastRun, failure, "宽限期保留守护进程信息")
            },
            TestCase("命令行：JSON 追加 dnsGuard，原有键不变，文本输出不变") { t in
                let settings = AppSettings(expectedDNS: ["192.0.2.53"])
                let written = DNSGuardEvent(date: now, phase: .connected, outcome: .written)
                var snapshot = DNSRuleTests.snapshot(saved: ["192.0.2.53"])
                snapshot.dnsGuard = installed(target: ["192.0.2.54"], state: DNSGuardState(lastRun: written, lastWrite: written))
                let local = DNSRuleTests.evaluate(snapshot, settings)
                let verdict = CLIVerdict.make(firstLocal: local, secondLocal: nil, siteResults: [],
                                              intranet: .notConfigured, full: false, checkedAt: now)
                let json = verdict.renderJSON(redactor: Redactor(), timeZone: utc)
                let object = try t.require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                let items = try t.require(object["items"] as? [[String: Any]])
                let dns = try t.require(items.first { $0["kind"] as? String == "primaryDNS" })
                t.expectEqual(Set(dns.keys), ["kind", "title", "severity", "conclusion", "evidence", "dnsGuard"])
                let guardObject = try t.require(dns["dnsGuard"] as? [String: Any])
                t.expectEqual(guardObject["installed"] as? Bool, true)
                let lastRun = try t.require(guardObject["lastRun"] as? [String: Any])
                t.expectEqual(lastRun["at"] as? String, "2026-09-26T12:00:00Z")
                t.expectEqual(lastRun["phase"] as? String, "connected")
                t.expectEqual(lastRun["outcome"] as? String, "written")
                t.expectNil(guardObject["lastWrite"])
                t.expectEqual(guardObject["notices"] as? [String],
                              ["守护进程的目标 DNS 为 192.0.2.54，与设置中的预期 DNS 192.0.2.53 不一致"])
                t.expect(items.filter { $0["kind"] as? String != "primaryDNS" }.allSatisfy { $0["dnsGuard"] == nil })

                let plain = CLIVerdict.make(firstLocal: DNSRuleTests.evaluate(DNSRuleTests.snapshot(saved: ["192.0.2.53"]), settings),
                                            secondLocal: nil, siteResults: [], intranet: .notConfigured,
                                            full: false, checkedAt: now)
                t.expectEqual(verdict.renderText(redactor: Redactor()), plain.renderText(redactor: Redactor()))
            },
            TestCase("诊断摘要：附守护进程状态与最近事件") { t in
                let settings = AppSettings(expectedDNS: target)
                let skipped = DNSGuardEvent(date: now, outcome: .skipped, reason: "TUN 未运行")
                var snapshot = DNSRuleTests.snapshot(saved: target)
                snapshot.dnsGuard = installed(state: DNSGuardState(lastRun: skipped), events: [skipped])
                let local = DNSRuleTests.evaluate(snapshot, settings)
                let summary = DiagnosticSummary(
                    generatedAt: now, appVersion: "0.0.0", osVersion: "macOS",
                    overall: OverallAssessment(local: local, connectivityFaults: []),
                    local: local, sites: [], intranetConfigured: false)
                let text = summary.render(redactor: Redactor(), timeZone: utc)
                t.expectContains(text, "  DNS 守护进程：已安装\n  最近一次（2026-09-26 12:00:00）：跳过（TUN 未运行）")
                t.expectContains(text, "  · 守护进程事件 2026-09-26 12:00:00：跳过（TUN 未运行）")
            },
        ])
    }
}
