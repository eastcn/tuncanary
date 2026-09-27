import Foundation
import TunCanaryCore
import TunCanaryUI

enum UIEgressIPTests {
    static var suite: TestSuite {
        TestSuite("UI.EgressIP", [
            TestCase("按需检测、防重入、结果不进入诊断或总体状态") { t in try await onDemand(t) },
            TestCase("取消后迟到出口结果不写回") { t in try await cancelled(t) },
        ])
    }

    @MainActor
    static func onDemand(_ t: TestContext) async throws {
        let checker = HeldChecker()
        let model = AppModel(egressChecker: checker)
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

    actor HeldChecker: EgressIPChecking {
        var count = 0
        var continuation: CheckedContinuation<[EgressIPResult], Never>?
        var requestedTargets: [[EgressIPTarget]] = []
        func check(targets: [EgressIPTarget]) async -> [EgressIPResult] {
            count += 1
            requestedTargets.append(targets)
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish() {
            continuation?.resume(returning: [EgressIPResult(target: .claude, checkedAt: Date(),
                ip: "203.0.113.21", ipVersion: .ipv4, location: "US", failure: nil)])
            continuation = nil
        }
    }
}
