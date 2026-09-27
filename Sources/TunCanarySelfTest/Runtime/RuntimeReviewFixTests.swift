import Foundation
import TunCanaryCore
import TunCanaryRuntime
import TunCanaryUI

/// 0.3.2 代码审查回归：设置变化只清零目标改变的站点（H1、L2），睡眠未唤醒时的恢复（M1）。
enum RuntimeReviewFixTests {
    private typealias Rig = RuntimeRig

    private static func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        try await RuntimeSuites.waitUntil(condition)
    }

    /// 后台轻测连续全部超时，达到告警门槛（三轮）后等待空闲。
    private static func failUntilAlert(_ rig: Rig, perRound: Int = 3) async throws {
        await rig.start()
        try await waitUntil { await rig.prober.count == perRound }
        try await waitUntil { await rig.model.checkProgress == nil }
        for round in 2...PulseConstants.consecutiveFailureThreshold {
            try await waitUntil { await rig.clock.hasSleeper(after: 120) }
            await rig.clock.advance(120)
            try await waitUntil { await rig.prober.count == perRound * round }
            try await waitUntil { await rig.model.checkProgress == nil }
        }
    }

    private static func sites(_ edit: (inout [Site]) -> Void) -> [Site] {
        var sites = FixtureLoader.legacySites
        edit(&sites)
        return sites
    }

    private static func index(_ id: String) -> Int {
        FixtureLoader.legacySites.firstIndex { $0.id == id }!
    }

    static var suite: TestSuite {
        TestSuite("Runtime.ReviewFixes", [
            TestCase("H1：改名与改组保留告警计数、历史且不重复通知") { t in
                let rig = try await Rig(category: .timeout)
                try await failUntilAlert(rig)
                let before = await rig.model.overall.faultKeys
                t.expect(before.contains(.group(.mainland)) && before.contains(.group(.overseas)))
                let notices = await rig.notifier.count

                let renamed = sites {
                    $0[index("google")].name = "谷歌"
                    $0[index("bilibili")].group = SiteGroup(rawValue: "视频")
                }
                await rig.settingsDidChange(AppSettings(sites: renamed))
                try await waitUntil { await rig.prober.count == 12 }
                try await waitUntil { await rig.model.checkProgress == nil }
                let after = await rig.model.overall.faultKeys
                t.expect(after.contains(.group(.mainland)), "百度的连续失败计数不应被清零")
                t.expect(after.contains(.group(.overseas)), "Google 改名后计数应保留")
                let noticesAfter = await rig.notifier.count
                t.expectEqual(noticesAfter, notices, "故障未恢复，不应重复通知")
                let history = await rig.model.siteHistory.recent(for: "google")
                t.expectEqual(history.count, 4, "改名后历史应保留")
                t.expect(history.allSatisfy { $0.site.name == "谷歌" }, "保留的历史应使用新名称")

                // 预期 DNS 不影响站点可达性：本机转红，但站点计数不清零。
                await rig.settingsDidChange(AppSettings(expectedDNS: ["119.29.29.29", "223.5.5.5"],
                                                        sites: renamed))
                try await waitUntil { await rig.prober.count == 15 }
                try await waitUntil { await rig.model.checkProgress == nil }
                let afterDNS = await rig.model.overall.faultKeys
                t.expect(afterDNS.contains(.group(.mainland)), "预期 DNS 变化不应清零站点计数")
                t.expect(afterDNS.contains(.group(.overseas)))
                await rig.stop()
            },
            TestCase("H1：URL、后台开关、启停改变或删除只清零对应站点") { t in
                let rig = try await Rig(category: .timeout)
                try await failUntilAlert(rig)

                // Claude 改 URL：只清零 Claude；Google 保留计数，单站黄色。
                var current = sites { $0[index("claude")].url = URL(string: "https://claude.ai/login")! }
                await rig.settingsDidChange(AppSettings(sites: current))
                try await waitUntil { await rig.prober.count == 12 }
                try await waitUntil { await rig.model.checkProgress == nil }
                var keys = await rig.model.overall.faultKeys
                t.expect(keys.contains(.site("google")), "Google 的计数应保留")
                t.expect(!keys.contains(.site("claude")), "Claude 目标改变，计数应清零")
                t.expect(!keys.contains(.group(.overseas)))
                t.expect(keys.contains(.group(.mainland)), "百度的计数应保留")
                let claudeHistory = await rig.model.siteHistory.recent(for: "claude")
                t.expectEqual(claudeHistory.count, 1, "旧 URL 的历史应清除")

                // 关闭 Google 的后台检测再打开：计数重新开始。
                current[index("google")].isKey = false
                current[index("google")].inLightProbe = false
                await rig.settingsDidChange(AppSettings(sites: current))
                try await waitUntil { await rig.prober.count == 14 }
                try await waitUntil { await rig.model.checkProgress == nil }
                current[index("google")].isKey = true
                current[index("google")].inLightProbe = true
                // 同时删除百度：计数清零。
                let baidu = current.remove(at: index("baidu"))
                await rig.settingsDidChange(AppSettings(sites: current))
                try await waitUntil { await rig.prober.count == 16 }
                try await waitUntil { await rig.model.checkProgress == nil }
                keys = await rig.model.overall.faultKeys
                t.expect(!keys.contains(.site("google")), "后台开关改变后 Google 应从头计数")
                t.expect(keys.contains(.site("claude")), "Claude 已连续失败三轮以上")

                // 重新加回百度：从头计数。
                current.insert(baidu, at: 0)
                await rig.settingsDidChange(AppSettings(sites: current))
                try await waitUntil { await rig.prober.count == 19 }
                try await waitUntil { await rig.model.checkProgress == nil }
                keys = await rig.model.overall.faultKeys
                t.expect(!keys.contains(.group(.mainland)), "删除后重新加入的百度应从头计数")
                await rig.stop()
            },
            TestCase("H1：内网 URL 改变只清零内网") { t in
                let intranet = URL(string: "https://intranet.corp.example/health")!
                let rig = try await Rig(category: .timeout, settings: AppSettings(intranetURL: intranet),
                                        scenario: .b)
                try await failUntilAlert(rig, perRound: 4)
                let before = await rig.model.overall.faultKeys
                t.expect(before.contains(.site(SiteCatalog.intranetID)))

                await rig.settingsDidChange(AppSettings(intranetURL: URL(string: "https://portal.corp.example/")!))
                try await waitUntil { await rig.prober.count == 16 }
                try await waitUntil { await rig.model.checkProgress == nil }
                let after = await rig.model.overall.faultKeys
                t.expect(!after.contains(.site(SiteCatalog.intranetID)), "内网目标改变，计数应清零")
                t.expect(after.contains(.group(.mainland)), "公开站点计数应保留")
                let intranetHistory = await rig.model.siteHistory.recent(for: SiteCatalog.intranetID)
                t.expectEqual(intranetHistory.count, 1, "旧内网 URL 的历史应清除")
                await rig.stop()
            },
            TestCase("L2：站点 ID 重复时保留历史不崩溃") { t in
                let rig = try await Rig()
                await rig.start()
                try await waitUntil { await rig.prober.count == 3 }
                try await waitUntil { await rig.model.checkProgress == nil }
                var duplicate = SiteCatalog.google
                duplicate.name = "Google 副本"
                await rig.settingsDidChange(AppSettings(sites: FixtureLoader.legacySites + [duplicate]))
                try await waitUntil { await rig.model.checkProgress == nil }
                let history = await rig.model.siteHistory.recent(for: "google")
                t.expect(!history.isEmpty)
                await rig.stop()
            },
            TestCase("M1：睡眠清除宽限结束时间；未收到唤醒时手动复测恢复调度") { t in
                let rig = try await Rig()
                await rig.start()
                try await waitUntil { await rig.prober.count == 3 }
                rig.observer.emit(.network)
                try await waitUntil { await rig.model.graceEndsAt != nil }
                rig.observer.emit(.sleep)
                try await waitUntil { await rig.model.graceEndsAt == nil }
                try await waitUntil { await rig.clock.uptimePendingCount == 1 }
                try await waitUntil { await rig.model.checkProgress == nil }
                // 睡眠中越过原宽限期；未到 60 秒兜底。
                await rig.clock.advance(10)
                for _ in 0..<50 { await Task.yield() }

                await rig.recheck()
                try await waitUntil { await rig.prober.count >= 12 }
                try await waitUntil { await rig.model.checkProgress == nil }
                let collected = await rig.provider.count
                try await waitUntil { await rig.clock.hasSleeper(after: 20) }
                await rig.clock.advance(20)
                try await waitUntil { await rig.provider.count > collected }
                await rig.stop()
            },
            TestCase("M1：未收到唤醒时保存设置恢复调度") { t in
                let rig = try await Rig()
                await rig.start()
                try await waitUntil { await rig.prober.count == 3 }
                try await waitUntil { await rig.model.checkProgress == nil }
                rig.observer.emit(.sleep)
                try await waitUntil { await rig.clock.uptimePendingCount == 1 }
                await rig.settingsDidChange(AppSettings(notificationsEnabled: false))
                try await waitUntil { await rig.prober.count == 6 }
                try await waitUntil { await rig.model.checkProgress == nil }
                let collected = await rig.provider.count
                try await waitUntil { await rig.clock.hasSleeper(after: 20) }
                await rig.clock.advance(20)
                try await waitUntil { await rig.provider.count > collected }
                await rig.stop()
            },
            TestCase("M1：睡眠 60 秒（单调时钟）仍未唤醒时自动恢复") { t in
                let rig = try await Rig()
                await rig.start()
                try await waitUntil { await rig.prober.count == 3 }
                try await waitUntil { await rig.model.checkProgress == nil }
                rig.observer.emit(.sleep)
                try await waitUntil { await rig.clock.uptimePendingCount == 1 }
                await rig.clock.advance(59)
                for _ in 0..<50 { await Task.yield() }
                let duringSleep = await rig.prober.count
                t.expectEqual(duringSleep, 3, "兜底计时器到点前保持暂停")
                await rig.clock.advance(1)
                try await waitUntil { await rig.prober.count == 6 }
                try await waitUntil { await rig.model.checkProgress == nil }
                let collected = await rig.provider.count
                try await waitUntil { await rig.clock.hasSleeper(after: 20) }
                await rig.clock.advance(20)
                try await waitUntil { await rig.provider.count > collected }
                await rig.stop()
            },
        ])
    }
}
