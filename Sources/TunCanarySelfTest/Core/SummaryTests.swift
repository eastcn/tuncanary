import Foundation
import TunCanaryCore

enum SummaryTests {
    typealias F = FixtureLoader

    static func connectivityFaults(_ failing: Set<String>) -> [ConnectivityFault] {
        ConnectivityTracker.faults(failingSiteIDs: failing, context: .consecutiveRounds)
    }

    static var suite: TestSuite {
        TestSuite("Core.Summary", [
            TestCase("总体取最严重的一项，原因按严重程度排序") { t in
                let local = F.evaluate(try F.snapshot(.c))
                let overall = OverallAssessment(local: local, connectivityFaults: connectivityFaults(["google"]))
                t.expectEqual(overall.severity, .critical)
                t.expectEqual(overall.reasons.map(\.severity), [.critical, .warning])
                t.expectEqual(overall.primaryReason, "主网络 DNS（Wi-Fi）：VPN 已断开、TUN 运行中，DNS 未恢复为 119.29.29.29")
                t.expectEqual(overall.tooltip,
                              "TunCanary：故障 — 主网络 DNS（Wi-Fi）：VPN 已断开、TUN 运行中，DNS 未恢复为 119.29.29.29")
                t.expectEqual(Set(overall.faultKeys), [.dnsNotRestored, .site("google")])
            },
            TestCase("本机正常 + 百度三轮失败 → 红") { t in
                let local = F.evaluate(try F.snapshot(.a))
                let overall = OverallAssessment(local: local, connectivityFaults: connectivityFaults(["baidu"]))
                t.expectEqual(overall.severity, .critical)
                t.expectEqual(overall.primaryReason, "百度连续三轮访问失败，国内出口故障")
            },
            TestCase("黄 > 灰：本机未确认 + Google 失败 → 黄") { t in
                let local = F.evaluate(F.addingProcess(try F.snapshot(.c), F.vpnProcess))
                t.expectEqual(local.severity, .unknown)
                let overall = OverallAssessment(local: local, connectivityFaults: connectivityFaults(["google"]))
                t.expectEqual(overall.severity, .warning)
                t.expectEqual(overall.primaryReason, "Google 连续三轮访问失败")
                t.expectEqual(overall.reasons.last?.severity, .unknown)
            },
            TestCase("全部正常与尚无结果") { t in
                let ok = OverallAssessment(local: F.evaluate(try F.snapshot(.a)), connectivityFaults: [])
                t.expectEqual(ok.severity, .ok)
                t.expectEqual(ok.primaryReason, "各项检查正常")
                t.expectEqual(ok.tooltip, "TunCanary：正常 — 各项检查正常")
                let none = OverallAssessment(local: nil, connectivityFaults: [])
                t.expectEqual(none.severity, .unknown)
                t.expectEqual(none.primaryReason, "尚无检查结果")
                t.expectEqual(none.statusText, "未确认")
            },
            TestCase("宽限期显示“切换中”") { t in
                let local = F.evaluate(try F.snapshot(.c), inGracePeriod: true)
                let overall = OverallAssessment(local: local, connectivityFaults: [])
                t.expectEqual(overall.severity, .unknown)
                t.expectEqual(overall.statusText, "切换中")
                t.expectEqual(overall.tooltip, "TunCanary：切换中 — 网络切换中")
                t.expectEqual(overall.faults, [])
            },
        ])
    }
}

enum NotificationTests {
    static func fault(_ key: FaultKey, _ severity: Severity, _ message: String = "消息") -> Fault {
        Fault(key: key, severity: severity, message: message)
    }

    static var suite: TestSuite {
        TestSuite("Core.NotificationDeduper", [
            TestCase("新进入黄或红时通知一次") { t in
                var deduper = NotificationDeduper()
                let first = deduper.update(with: [fault(.site("google"), .warning, "Google 连续三轮访问失败")])
                t.expectEqual(first.map(\.key), [.site("google")])
                t.expectEqual(first.first?.title, "TunCanary：需关注")
                t.expectEqual(first.first?.body, "Google 连续三轮访问失败")
                t.expectEqual(deduper.update(with: [fault(.site("google"), .warning)]), [])
                t.expectEqual(deduper.update(with: [fault(.site("google"), .warning)]), [])
            },
            TestCase("灰色不通知") { t in
                var deduper = NotificationDeduper()
                t.expectEqual(deduper.update(with: [fault("vpn.unconfirmed", .unknown), fault("x.ok", .ok)]), [])
                t.expectEqual(deduper.activeKeys, [])
            },
            TestCase("升级为新的键再通知一次（红在前）") { t in
                var deduper = NotificationDeduper()
                _ = deduper.update(with: [fault(.site("google"), .warning)])
                let escalated = deduper.update(with: [
                    fault(.site("google"), .warning),
                    fault(.site("claude"), .warning),
                    fault(.group(.overseas), .critical),
                ])
                t.expectEqual(escalated.map(\.key), [.group(.overseas), .site("claude")])
                t.expectEqual(escalated.first?.title, "TunCanary：故障")
                // 回落为单站失败：不通知。
                t.expectEqual(deduper.update(with: [fault(.site("google"), .warning)]), [])
            },
            TestCase("恢复后清除该键，之后可再次通知") { t in
                var deduper = NotificationDeduper()
                let dns = fault(.dnsNotRestored, .critical, "主网络 DNS（Wi-Fi）：DNS 未恢复")
                t.expectEqual(deduper.update(with: [dns]).count, 1)
                t.expectEqual(deduper.update(with: []), [], "恢复不通知")
                t.expectEqual(deduper.activeKeys, [])
                t.expectEqual(deduper.update(with: [dns]).count, 1, "再次出现时重新通知")
            },
            TestCase("只清除已恢复的键") { t in
                var deduper = NotificationDeduper()
                _ = deduper.update(with: [fault(.tunInactive, .warning), fault(.site("claude"), .warning)])
                _ = deduper.update(with: [fault(.site("claude"), .warning)])
                t.expectEqual(deduper.activeKeys, [.site("claude")])
                t.expectEqual(deduper.update(with: [fault(.site("claude"), .warning), fault(.tunInactive, .warning)]).map(\.key),
                              [.tunInactive])
            },
            TestCase("同一轮重复的键只通知一次") { t in
                var deduper = NotificationDeduper()
                let result = deduper.update(with: [fault(.dnsBypassProxy, .warning), fault(.dnsBypassProxy, .warning)])
                t.expectEqual(result.count, 1)
            },
            TestCase("通知正文不含 VPN 站点 URL，带处理提示") { t in
                let url = URL(string: "https://intranet.corp.example/health")!
                let redactor = Redactor(homeDirectory: "/Users/tester", intranetURL: url)
                var deduper = NotificationDeduper()
                let local = FixtureLoader.evaluate(try FixtureLoader.snapshot(.c))
                let intranetFault = ConnectivityTracker.faults(failingSiteIDs: ["intranet"], context: .consecutiveRounds)
                let leaky = Fault(key: "test.leak", severity: .warning, message: "访问 \(url.absoluteString) 失败（10.9.0.53）")
                let notes = deduper.update(with: local.faults + intranetFault.map(\.fault) + [leaky], redactor: redactor)
                t.expectEqual(notes.count, 3)
                for note in notes {
                    t.expectNotContains(note.body, "corp.example")
                    t.expectNotContains(note.body, "https://")
                    t.expectNotContains(note.body, "10.231")
                }
                let dns = try t.require(notes.first { $0.key == .dnsNotRestored })
                t.expectEqual(dns.body, "主网络 DNS（Wi-Fi）：VPN 已断开、TUN 运行中，DNS 未恢复为 119.29.29.29。等待 VPN 完全断开后，关闭并重新开启 Clash TUN")
            },
        ])
    }
}

enum GraceTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    static var suite: TestSuite {
        TestSuite("Core.GraceTracker", [
            TestCase("初始不在宽限期") { t in
                let tracker = GraceTracker()
                t.expect(!tracker.isInGracePeriod(at: t0))
                t.expectNil(tracker.graceEndsAt)
                t.expectEqual(tracker.remaining(at: t0), 0)
            },
            TestCase("网络变化后 10 秒内处于宽限期") { t in
                var tracker = GraceTracker()
                t.expect(tracker.noteChange(.network, at: t0))
                t.expect(tracker.isInGracePeriod(at: t0))
                t.expect(tracker.isInGracePeriod(at: t0.addingTimeInterval(9.9)))
                t.expect(!tracker.isInGracePeriod(at: t0.addingTimeInterval(10)))
                t.expectEqual(tracker.graceEndsAt, t0.addingTimeInterval(10))
                t.expectEqual(tracker.remaining(at: t0.addingTimeInterval(4)), 6)
            },
            TestCase("唤醒进入宽限期，睡眠不进入") { t in
                var tracker = GraceTracker()
                t.expect(!tracker.noteChange(.sleep, at: t0))
                t.expect(!tracker.isInGracePeriod(at: t0))
                t.expect(tracker.note(NetworkChangeEvent(reason: .wake, date: t0)))
                t.expectEqual(tracker.lastReason, .wake)
                t.expect(tracker.isInGracePeriod(at: t0.addingTimeInterval(1)))
            },
            TestCase("新的变化顺延宽限期，更早的事件忽略") { t in
                var tracker = GraceTracker()
                tracker.noteChange(.network, at: t0)
                tracker.noteChange(.network, at: t0.addingTimeInterval(8))
                t.expect(tracker.isInGracePeriod(at: t0.addingTimeInterval(15)))
                t.expectEqual(tracker.graceEndsAt, t0.addingTimeInterval(18))
                t.expect(!tracker.noteChange(.network, at: t0.addingTimeInterval(1)))
                t.expectEqual(tracker.graceEndsAt, t0.addingTimeInterval(18))
            },
        ])
    }
}
