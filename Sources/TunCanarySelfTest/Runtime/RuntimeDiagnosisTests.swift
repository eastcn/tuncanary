import Foundation
import TunCanaryCore
import TunCanaryRuntime
import TunCanaryUI

/// 记录诊断请求的桩：立即返回“日志中没有这次连接”。
actor RuntimeDiagnoserStub: SiteDiagnosing {
    private(set) var calls: [(siteID: String, manual: Bool)] = []

    nonisolated func diagnose(site: Site, tunRunning: Bool, manual: Bool) async -> SiteDiagnosis {
        await record(site.id, manual)
        return SiteDiagnosis(siteID: site.id, siteName: site.name, diagnosedAt: Date(), manual: manual,
                             outcome: .failure(.timeout), route: .notInProxy(tunRunning: tunRunning))
    }

    private func record(_ id: String, _ manual: Bool) { calls.append((id, manual)) }

    var count: Int { calls.count }
    func ids(manual: Bool) -> [String] { calls.filter { $0.manual == manual }.map(\.siteID).sorted() }
}

/// 站点失败诊断的触发规则：首次失败和失败类别变化时自动诊断，持续同类失败不重复，恢复后清除；手动随时可用。
enum RuntimeDiagnosisTests {
    private static func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        try await RuntimeSuites.waitUntil(condition)
    }

    static var suite: TestSuite {
        TestSuite("Runtime.Diagnosis", [
            TestCase("关闭时不诊断，也不显示按钮") { t in
                let diagnoser = RuntimeDiagnoserStub()
                let rig = try await RuntimeRig(category: .timeout, diagnoser: diagnoser)
                await rig.start()
                try await waitUntil { await rig.prober.count == 3 }
                try await waitUntil { await rig.model.checkProgress == nil }
                await MainActor.run { rig.controller.diagnose(siteID: "google") }
                let count = await diagnoser.count
                t.expectEqual(count, 0)
                let canDiagnose = await MainActor.run { rig.model.siteGroups.flatMap(\.rows).contains { $0.canDiagnose } }
                t.expect(!canDiagnose)
                await rig.stop()
            },
            TestCase("首次失败自动诊断；同类失败不重复；类别变化再诊断；恢复后清除") { t in
                var settings = FixtureLoader.legacySettings
                settings.proxyDiagnosticsEnabled = true
                let diagnoser = RuntimeDiagnoserStub()
                let rig = try await RuntimeRig(category: .timeout, settings: settings, diagnoser: diagnoser)
                await rig.start()
                try await waitUntil { await diagnoser.count == 3 }
                try await waitUntil { await rig.model.siteDiagnoses.count == 3 }
                let first = await diagnoser.ids(manual: false)
                t.expectEqual(first, ["baidu", "claude", "google"])
                let shown = await MainActor.run { rig.model.siteGroups.flatMap(\.rows).contains { !$0.diagnosisLines.isEmpty } }
                t.expect(shown)

                // 第二轮仍是超时：不重复诊断。
                await rig.clock.advance(120)
                try await waitUntil { await rig.prober.count == 6 }
                try await waitUntil { await rig.model.checkProgress == nil }
                let second = await diagnoser.count
                t.expectEqual(second, 3)

                // 失败类别变化：再诊断一次。
                await rig.prober.setCategory(.dnsFailure)
                await rig.clock.advance(120)
                try await waitUntil { await diagnoser.count == 6 }

                // 恢复：清除自动诊断的结果。
                await rig.prober.setCategory(.reachable)
                await rig.clock.advance(120)
                try await waitUntil { await rig.prober.count == 12 }
                try await waitUntil { await rig.model.checkProgress == nil }
                let cleared = await rig.model.siteDiagnoses.isEmpty
                t.expect(cleared)

                // 手动诊断：正常站点也可以诊断，结果保留。
                await MainActor.run { rig.controller.diagnose(siteID: "google") }
                try await waitUntil { await rig.model.siteDiagnoses["google"]?.manual == true }
                let manual = await diagnoser.ids(manual: true)
                t.expectEqual(manual, ["google"])

                // 关闭诊断：清除结果。
                var off = settings
                off.proxyDiagnosticsEnabled = false
                await rig.settingsDidChange(off)
                let offCleared = await rig.model.siteDiagnoses.isEmpty
                t.expect(offCleared)
                await rig.stop()
            },
        ])
    }
}
