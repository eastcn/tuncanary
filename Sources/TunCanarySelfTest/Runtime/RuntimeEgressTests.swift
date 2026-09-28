import Foundation
import TunCanaryCore
import TunCanaryUI

enum RuntimeEgressTests {
    static var suite: TestSuite {
        TestSuite("Runtime.Egress", [TestCase("自动错开目标、遵守间隔，睡眠和停止取消采样") { t in
            try await cadence(t)
        }])
    }

    @MainActor
    static func cadence(_ t: TestContext) async throws {
        var settings = AppSettings(egressTargets: [.cloudflare, .bytedance])
        settings.egressMonitoring.interval = 600
        let rig = try await RuntimeRig(settings: settings)
        let checker = UIEgressIPTests.HeldChecker()
        rig.model.egressChecker = checker
        rig.model.now = rig.clock.monitorClock().now
        rig.start()
        defer { rig.stop() }
        try await UIEgressIPTests.awaitStarted(checker)
        await checker.finish(at: rig.model.now())
        try await UIEgressIPTests.awaitFinished(rig.model)
        try await RuntimeSuites.waitUntil { await rig.clock.hasSleeper(after: 30) }
        let initial = await checker.requestedTargets
        t.expectEqual(initial, [[.cloudflare]], "自动首轮只请求一个目标")
        await rig.clock.advance(30)
        try await UIEgressIPTests.awaitStarted(checker, expected: 2)
        await checker.finish(at: rig.model.now())
        try await UIEgressIPTests.awaitFinished(rig.model)
        let second = await checker.requestedTargets
        t.expectEqual(second.last, [.bytedance])
        try await RuntimeSuites.waitUntil { await rig.clock.hasSleeper(after: 30) }
        await rig.clock.advance(540)
        for _ in 0..<100 { await Task.yield() }
        let before = await checker.count
        t.expectEqual(before, 2, "未满十分钟不重新请求")
        try await RuntimeSuites.waitUntil { await rig.clock.hasSleeper(after: 30) }
        settings.egressMonitoring.interval = 1200
        rig.settingsDidChange(settings)
        try await RuntimeSuites.waitUntil { await rig.clock.hasSleeper(after: 30) }
        await rig.clock.advance(30)
        for _ in 0..<100 { await Task.yield() }
        let extended = await checker.count
        t.expectEqual(extended, 2, "保存较长间隔立即生效")
        settings.egressMonitoring.interval = 600
        rig.settingsDidChange(settings)
        try await RuntimeSuites.waitUntil { await rig.clock.hasSleeper(after: 30) }
        await rig.clock.advance(30)
        try await UIEgressIPTests.awaitStarted(checker, expected: 3)
        rig.observer.emit(.sleep)
        try await RuntimeSuites.waitUntil { !rig.model.isCheckingEgress }
        await checker.finish(at: rig.model.now())
        await rig.clock.advanceAsleep(3600)
        for _ in 0..<100 { await Task.yield() }
        let asleep = await checker.count
        t.expectEqual(asleep, 3, "睡眠时不请求")
        t.expectEqual(rig.model.egressState.history.count, 2, "取消后的迟到结果不记录")
        rig.observer.emit(.wake)
        try await RuntimeSuites.waitUntil { rig.model.graceEndsAt != nil }
        try await RuntimeSuites.waitUntil { await rig.clock.hasSleeper(after: 10) }
        await rig.clock.advance(10)
        try await UIEgressIPTests.awaitStarted(checker, expected: 4)
        await checker.finish(at: rig.model.now())
        try await UIEgressIPTests.awaitFinished(rig.model)
        t.expectEqual(rig.model.egressState.history.count, 3, "唤醒后在宽限期末恢复采样")
        rig.stop()
        await rig.clock.advance(3600)
        for _ in 0..<100 { await Task.yield() }
        let stopped = await checker.count
        t.expectEqual(stopped, 4, "停止后不请求")
    }
}
