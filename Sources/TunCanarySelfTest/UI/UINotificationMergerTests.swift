import Foundation
import TunCanaryCore
import TunCanaryUI

/// 通知合并（计划：同一轮的多条通知合并为一条，标题取最严重的状态，正文逐条列出原因）。
enum UINotificationMergerTests {
    static func note(_ key: FaultKey, _ severity: Severity, _ body: String) -> PendingNotification {
        PendingNotification(key: key, severity: severity, title: "\(AppIdentity.displayName)：\(severity.displayName)", body: body)
    }

    static var suite: TestSuite {
        TestSuite("UI.NotificationMerger", [
            TestCase("空数组返回 nil") { t in
                t.expectNil(NotificationMerger.merge([]))
            },
            TestCase("只有一条时原样返回") { t in
                let single = note(.site("google"), .warning, "Google 连续两轮访问失败")
                t.expectEqual(NotificationMerger.merge([single]), single)
            },
            TestCase("多条合并：标题取最严重的状态，正文逐条列出") { t in
                // 与 NotificationDeduper 的实际输出衔接：Google 与 GitHub 同时失败两轮，返回 3 条。
                var deduper = NotificationDeduper()
                let faults = ConnectivityTracker.faults(failingSiteIDs: ["google", "github"], context: .consecutiveRounds)
                    .map(\.fault)
                let pending = deduper.update(with: faults)
                t.expectEqual(pending.count, 3)
                let merged = try t.require(NotificationMerger.merge(pending))
                t.expectEqual(merged.severity, .critical)
                t.expectEqual(merged.key, .group(.overseas))
                t.expectEqual(merged.title, "TunCanary：故障")
                t.expectEqual(merged.body, """
                [故障] Google 与 GitHub 均连续两轮访问失败，海外访问故障
                [需关注] Google 连续两轮访问失败
                [需关注] GitHub 连续两轮访问失败
                """)
            },
            TestCase("按严重程度降序，同级保持原顺序") { t in
                let merged = try t.require(NotificationMerger.merge([
                    note("a", .warning, "甲"),
                    note("b", .critical, "乙"),
                    note("c", .warning, "丙"),
                    note("d", .critical, "丁"),
                ]))
                t.expectEqual(merged.key, "b")
                t.expectEqual(merged.body.components(separatedBy: "\n"), ["[故障] 乙", "[故障] 丁", "[需关注] 甲", "[需关注] 丙"])
            },
            TestCase("全部为黄时标题为“需关注”") { t in
                let merged = try t.require(NotificationMerger.merge([
                    note(.site("google"), .warning, "Google 连续两轮访问失败"),
                    note(.dnsBypassProxy, .warning, "主网络 DNS（Wi-Fi）：系统 DNS 未经过 Clash"),
                ]))
                t.expectEqual(merged.title, "TunCanary：需关注")
                t.expectEqual(merged.severity, .warning)
            },
            TestCase("经去重器脱敏后合并，正文不含内网站点 URL") { t in
                let url = URL(string: "https://intranet.corp.example/health")!
                var deduper = NotificationDeduper()
                let pending = deduper.update(with: [
                    Fault(key: .site(SiteCatalog.intranetID), severity: .warning,
                          message: "内网站点连续两轮访问失败（https://intranet.corp.example/health）"),
                    Fault(key: .dnsNotRestored, severity: .critical, message: "主网络 DNS（Wi-Fi）：DNS 为 10.20.0.53"),
                ], redactor: Redactor(intranetURL: url))
                let merged = try t.require(NotificationMerger.merge(pending))
                t.expectNotContains(merged.body, "intranet.corp.example")
                t.expectNotContains(merged.body, "10.20.0.53")
                t.expectContains(merged.body, "[内网站点]")
                t.expectContains(merged.body, "10.x.x.x")
            },
        ])
    }
}
