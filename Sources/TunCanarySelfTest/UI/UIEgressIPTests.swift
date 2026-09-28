import Foundation
import TunCanaryCore
import TunCanaryUI

enum UIEgressIPTests {
    static var suite: TestSuite {
        TestSuite("UI.EgressIP", [
            TestCase("各目标详情默认收起、独立展开，关闭重置且不影响后台采样") { t in
                await disclosure(t)
            },
            TestCase("按需检测、防重入、结果不进入诊断或总体状态") { t in try await onDemand(t) },
            TestCase("地域缓存跨目标共用，手动不能绕过冷却，重启保留历史") { t in try await persistenceAndCache(t) },
            TestCase("自定义端点、地域规则和自动间隔设置往返") { t in try await settingsRoundTrip(t) },
            TestCase("取消后迟到出口结果不写回") { t in try await cancelled(t) },
        ])
    }

    @MainActor
    static func disclosure(_ t: TestContext) {
        let model = AppModel()
        let automatic = model.settings.egressMonitoring.automatic
        t.expect(model.expandedEgressTargets.isEmpty)
        model.toggleEgressDetails(.cloudflare)
        t.expectEqual(model.expandedEgressTargets, [.cloudflare])
        model.toggleEgressDetails(.claude)
        t.expectEqual(model.expandedEgressTargets, [.cloudflare, .claude])
        model.toggleEgressDetails(.cloudflare)
        t.expectEqual(model.expandedEgressTargets, [.claude])
        model.popoverDidClose()
        t.expect(model.expandedEgressTargets.isEmpty)
        t.expectEqual(model.settings.egressMonitoring.automatic, automatic)
    }

    @MainActor
    static func onDemand(_ t: TestContext) async throws {
        let checker = HeldChecker()
        var date = Date()
        let model = AppModel(now: { date }, egressChecker: checker)
        let overall = model.overall
        let before = await checker.count
        t.expectEqual(before, 0)
        model.checkEgressIP()
        model.checkEgressIP()
        try await awaitStarted(checker)
        let count = await checker.count
        t.expectEqual(count, 1)
        t.expect(model.isCheckingEgress)
        await checker.finish()
        for _ in 0..<1000 {
            if !model.isCheckingEgress { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        t.expect(!model.isCheckingEgress)
        t.expectEqual(model.egressResults.first?.ip, "203.0.113.21")
        t.expectEqual(model.overall, overall)
        t.expect(!AppModel.defaultDiagnosticText(model).contains("203.0.113.21"))
        let firstTargets = await checker.requestedTargets
        t.expectEqual(firstTargets, [[.cloudflare]], "默认只检测 Cloudflare")
        date = date.addingTimeInterval(301)
        model.settings.egressTargets = [.cloudflare, .claude]
        model.checkEgressIP()
        t.expect(model.egressResults.isEmpty, "重新检测不能保留旧IP冒充新结果")
        try await awaitStarted(checker, expected: 2)
        let secondTargets = await checker.requestedTargets
        t.expectEqual(secondTargets.last, [.cloudflare, .claude], "按固定顺序检测")
        model.cancelEgressIP()
        await checker.finish()
    }

    @MainActor
    static func cancelled(_ t: TestContext) async throws {
        let checker = HeldChecker()
        let model = AppModel(egressChecker: checker)
        model.checkEgressIP()
        try await awaitStarted(checker)
        model.cancelEgressIP()
        await checker.finish()
        for _ in 0..<20 { await Task.yield() }
        t.expect(!model.isCheckingEgress)
        t.expect(model.egressResults.isEmpty)
    }

    static func awaitStarted(_ checker: HeldChecker, expected: Int = 1) async throws {
        for _ in 0..<1000 {
            if await checker.count >= expected { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NSError(domain: "EgressTestDidNotStart", code: 1)
    }

    @MainActor
    static func persistenceAndCache(_ t: TestContext) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("egress-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        var date = Date()
        let checker = HeldChecker(); let geo = GeoStub(date: date)
        var settings = AppSettings(egressTargets: [.cloudflare, .claude])
        settings.egressMonitoring.allowedRegions = ["claude": ["JP"]]
        let model = AppModel(settings: settings, now: { date }, egressChecker: checker, egressGeoClient: geo,
                             egressHistoryStore: EgressHistoryStore(fileURL: url))
        var alerts: [EgressAlert] = []
        model.deliverEgressAlert = { alerts.append($0) }
        model.checkEgressIP()
        try await awaitStarted(checker)
        await checker.finish(at: date)
        try await awaitFinished(model)
        let firstGeoCount = await geo.count
        t.expectEqual(firstGeoCount, 1, "相同 IP 两个目标只查询一次")
        t.expectEqual(model.egressState.history.count, 2)
        t.expect(alerts.isEmpty)
        model.checkEgressIP()
        for _ in 0..<20 { await Task.yield() }
        let firstCheckCount = await checker.count
        t.expectEqual(firstCheckCount, 1, "手动按钮不能绕过冷却")
        date = date.addingTimeInterval(301)
        model.checkEgressIP()
        try await awaitStarted(checker, expected: 2)
        await checker.finish(at: date)
        try await awaitFinished(model)
        let secondGeoCount = await geo.count
        t.expectEqual(secondGeoCount, 1, "命中缓存不再查地域")
        t.expectEqual(alerts.first?.kind, .regionViolation)
        let restarted = AppModel(settings: settings, now: { date }, egressChecker: checker, egressGeoClient: geo,
                                 egressHistoryStore: EgressHistoryStore(fileURL: url))
        t.expectEqual(restarted.egressState.history.count, 4)
        t.expect(restarted.egressState.regionAlerts["claude"]?.active == true)
        restarted.checkEgressIP()
        for _ in 0..<20 { await Task.yield() }
        let finalCheckCount = await checker.count
        t.expectEqual(finalCheckCount, 2, "重启不能绕过冷却")
    }

    @MainActor
    static func settingsRoundTrip(_ t: TestContext) async throws {
        let target = try t.require(EgressIPTarget.endpoint(EgressEndpoint(name: "国内", url: URL(string: "https://echo.example.test/ip")!, method: .json, selector: "data.ip")))
        var settings = AppSettings(egressTargets: [.cloudflare, .bytedance, target])
        settings.egressMonitoring.interval = 600
        settings.egressMonitoring.notifyIPChanges = true
        settings.egressMonitoring.allowedRegions[target.rawValue] = ["CN", "HK", "TW"]
        let draft = SettingsDraft(settings: settings)
        let validated = try t.require(draft.validate().settings)
        t.expectEqual(validated, settings)
        var invalid = draft; invalid.egressIntervalMinutes = "4"
        t.expect(!invalid.validate().isValid)
        t.expect(invalid.validate().tabsWithErrors.contains(.sites))
        let suite = "egress-ui-store-\(UUID().uuidString)"
        let defaults = try t.require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.save(validated)
        t.expectEqual(store.load(), validated)
    }

    @MainActor
    static func awaitFinished(_ model: AppModel) async throws {
        for _ in 0..<2000 {
            if !model.isCheckingEgress { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NSError(domain: "EgressTestDidNotFinish", code: 1)
    }

    actor GeoStub: EgressGeoLookingUp {
        var count = 0
        let date: Date
        init(date: Date) { self.date = date }
        func lookup(ip: String) async -> EgressGeoLookup {
            count += 1
            return EgressGeoLookup(geo: EgressGeo(ip: ip, countryCode: "US", checkedAt: date))
        }
    }

    actor HeldChecker: EgressIPChecking {
        var count = 0
        var continuation: CheckedContinuation<[EgressIPResult], Never>?
        var requestedTargets: [[EgressIPTarget]] = []
        func check(targets: [EgressIPTarget]) async -> [EgressIPResult] {
            count += 1
            requestedTargets.append(targets)
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish(at date: Date = Date()) {
            continuation?.resume(returning: (requestedTargets.last ?? []).map { EgressIPResult(target: $0, checkedAt: date,
                ip: "203.0.113.21", ipVersion: .ipv4, location: "US", failure: nil) })
            continuation = nil
        }
    }
}
