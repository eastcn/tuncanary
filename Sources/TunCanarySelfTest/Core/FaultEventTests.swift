import Foundation
import TunCanaryCore

/// 故障事件：记录器的出现、变化、消失，日志文件的截断与容错，以及诊断摘要中的最近事件。
enum FaultEventTests {
    static let start = Date(timeIntervalSince1970: 1_790_424_000)

    static func fault(_ key: FaultKey, _ severity: Severity, _ message: String) -> Fault {
        Fault(key: key, severity: severity, message: message)
    }

    static func temporaryLog() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("np-events-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested/events.jsonl")
    }

    static var suite: TestSuite {
        TestSuite("Core.FaultEvents", [
            TestCase("记录器：出现、同键不重复、升级、消失") { t in
                var recorder = FaultEventRecorder()
                let dns = fault(.dnsNotRestored, .critical, "DNS 未恢复为 10.9.0.53")
                let google = fault(.site("google"), .warning, "Google 连续三轮访问失败")
                let redactor = Redactor()

                let first = recorder.update(with: [dns, google, fault(.tunInactive, .unknown, "灰色不记录")],
                                            at: start, redactor: redactor)
                t.expectEqual(first.map(\.kind), [.appeared, .appeared])
                t.expectEqual(first.map(\.key), [.dnsNotRestored, .site("google")])
                t.expectEqual(first[0].message, "DNS 未恢复为 10.x.x.x", "事件描述要脱敏")
                t.expectEqual(first[0].text, "出现：DNS 未恢复为 10.x.x.x")

                t.expectEqual(recorder.update(with: [dns, google], at: start.addingTimeInterval(20), redactor: redactor), [])

                let escalated = fault(.site("google"), .critical, "Google 连续三轮访问失败")
                let second = recorder.update(with: [escalated], at: start.addingTimeInterval(40), redactor: redactor)
                t.expectEqual(second.map(\.kind), [.cleared, .changed])
                t.expectEqual(second[0].key, .dnsNotRestored)
                t.expectEqual(second[0].severity, .critical, "消失事件保留消失前的严重程度")
                t.expectEqual(second[0].displaySeverity, .unknown)
                t.expectEqual(second[0].text, "消失（已恢复或无法确认）：DNS 未恢复为 10.x.x.x")
                t.expectEqual(second[1].text, "变为故障：Google 连续三轮访问失败")

                let third = recorder.update(with: [], at: start.addingTimeInterval(60), redactor: redactor)
                t.expectEqual(third.map(\.kind), [.cleared])
                t.expect(recorder.active.isEmpty)
                t.expectEqual(FaultEvent(date: start, kind: .started).text, "开始监控")
            },
            TestCase("日志：追加、跨实例读取、只保留最近 200 条") { t in
                let url = temporaryLog()
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
                let store = FaultEventStore(fileURL: url)
                t.expectEqual(store.recent(), [], "文件不存在时为空")

                let started = FaultEvent(date: start, kind: .started)
                let appeared = FaultEvent(date: start.addingTimeInterval(1), kind: .appeared, key: .dnsBypassProxy,
                                          severity: .critical, message: "系统 DNS 未经过代理")
                store.append([started, appeared])
                t.expectEqual(FaultEventStore(fileURL: url).recent(), [started, appeared])
                t.expectEqual(store.recent(limit: 1), [appeared])

                let many = (0..<250).map {
                    FaultEvent(date: start.addingTimeInterval(TimeInterval(10 + $0)), kind: .started)
                }
                store.append(many)
                let kept = store.recent()
                t.expectEqual(kept.count, FaultEventStore.maxEvents)
                t.expectEqual(kept.last, many.last)
                t.expectEqual(kept.first, many[50])
            },
            TestCase("日志：损坏的行被跳过，下次写入时丢弃") { t in
                let url = temporaryLog()
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let valid = #"{"date":"2026-09-26T12:00:00Z","kind":"started","message":""}"#
                try Data("not json\n\(valid)\n{\"kind\":\"bogus\"}\n".utf8).write(to: url)
                let store = FaultEventStore(fileURL: url)
                t.expectEqual(store.recent(), [FaultEvent(date: start, kind: .started)])
                store.append([FaultEvent(date: start.addingTimeInterval(5), kind: .started)])
                let text = try String(contentsOf: url, encoding: .utf8)
                t.expectEqual(text.split(separator: "\n").count, 2)
                t.expectNotContains(text, "not json")
            },
            TestCase("诊断摘要附带最近事件，全文脱敏") { t in
                let events = [
                    FaultEvent(date: start, kind: .started),
                    FaultEvent(date: start.addingTimeInterval(60), kind: .appeared, key: .dnsNotRestored,
                               severity: .critical, message: "DNS 未恢复为 192.168.0.1"),
                ]
                let summary = DiagnosticSummary(
                    generatedAt: start, appVersion: "0.1.0", osVersion: "14.0",
                    overall: OverallAssessment(local: nil, connectivityFaults: []), local: nil,
                    sites: [], intranetConfigured: false, events: events)
                let text = summary.render(redactor: Redactor(), timeZone: TimeZone(identifier: "UTC")!)
                t.expectContains(text, "最近事件：\n- 2026-09-26 12:00:00 [未确认] 开始监控\n- 2026-09-26 12:01:00 [故障] 出现：DNS 未恢复为 192.x.x.x")
                t.expectNotContains(text, "192.168.0.1")
                let empty = DiagnosticSummary(
                    generatedAt: start, appVersion: "0.1.0", osVersion: "14.0",
                    overall: OverallAssessment(local: nil, connectivityFaults: []), local: nil,
                    sites: [], intranetConfigured: false)
                t.expectNotContains(empty.render(redactor: Redactor()), "最近事件")
            },
        ])
    }
}
