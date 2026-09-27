import Foundation
import TunCanaryCore
import TunCanaryRuntime
import TunCanaryUI

enum RuntimeSuites {
    static var all: [TestSuite] { [suite, RuntimeReviewFixTests.suite, RuntimeDiagnosisTests.suite] }

    private static var suite: TestSuite {
        TestSuite("Runtime.MonitorController", [
            TestCase("自定义周期在启动与保存后生效，旧周期取消") { t in
                let rig = try await RuntimeRig(settings: AppSettings(localCheckInterval: 30, lightProbeInterval: 60))
                await rig.start()
                try await waitUntil {
                    let idle = await rig.model.checkProgress == nil
                    let count = await rig.provider.count
                    return idle && count == 1
                }
                // 让两个定时器都进入虚拟时钟等待，再推进时间。
                try await waitUntil { await rig.clock.pendingCount >= 2 }
                await rig.clock.advance(20)
                for _ in 0..<20 { await Task.yield() }
                let beforeDeadline = await rig.provider.count
                t.expectEqual(beforeDeadline, 1, "不应再使用旧的 20 秒周期")
                await rig.clock.advance(10)
                try await waitUntil { await rig.provider.count == 2 }
                await rig.clock.advance(30)
                try await waitUntil { await rig.prober.count == 6 }
                try await waitUntil { await rig.model.checkProgress == nil }

                await rig.settingsDidChange(AppSettings(localCheckInterval: 5, lightProbeInterval: 15))
                try await waitUntil { await rig.prober.count == 9 }
                try await waitUntil { await rig.model.checkProgress == nil }
                try await waitUntil {
                    let local = await rig.clock.hasSleeper(after: 5)
                    let light = await rig.clock.hasSleeper(after: 15)
                    return local && light
                }
                let baseline = await rig.provider.count
                await rig.clock.advance(5)
                try await waitUntil { await rig.provider.count > baseline }
                let localOnlyProbeCount = await rig.prober.count
                t.expectEqual(localOnlyProbeCount, 9)
                await rig.clock.advance(10)
                try await waitUntil { await rig.prober.count == 12 }
                await rig.stop()
            },
            TestCase("自定义站点按后台和完整范围检测；清空配置丢弃旧轮次与历史") { t in
                let custom = Site(id: "new-target", name: "新目标", group: .overseas,
                                  url: URL(string: "https://custom.example/")!, isKey: true, inLightProbe: true)
                let manual = Site(id: "manual-target", name: "仅手动", group: .overseas,
                                  url: URL(string: "https://manual.example/")!, isKey: false, inLightProbe: false)
                let rig = try await RuntimeRig(settings: AppSettings(sites: [custom, manual]))
                await rig.start()
                try await waitUntil { await rig.prober.count == 1 }
                try await waitUntil { await rig.model.checkProgress == nil }
                let initial = await rig.prober.requests
                t.expectEqual(initial.map(\.id), [custom.id])
                let historyCount = await rig.model.siteHistory.recent(for: custom.id).count
                t.expectEqual(historyCount, 1)

                await rig.prober.holdNextBatch()
                await rig.recheck()
                try await waitUntil { await rig.prober.count == 3 }
                await rig.settingsDidChange(AppSettings(sites: []))
                await rig.prober.releaseHeld()
                try await waitUntil { await rig.provider.count >= 3 }
                try await waitUntil { await rig.model.checkProgress == nil }
                let history = await rig.model.siteHistory.results
                t.expect(history.isEmpty, "已删除目标的旧结果不能在取消后重新写回")
                let requests = await rig.prober.requests
                t.expectEqual(requests.count, 3, "空配置不应回退到内置站点")
                t.expectEqual(Set(requests.suffix(2).map(\.id)), [custom.id, manual.id])
                t.expect(requests.suffix(2).allSatisfy { $0.attempts == 3 })
                await rig.stop()
            },
            TestCase("20 秒本机检查与 120 秒轻测分开调度") { t in
                let rig = try await RuntimeRig()
                await rig.start()
                try await waitUntil {
                    let collected = await rig.provider.count
                    let probed = await rig.prober.count
                    return collected == 1 && probed == 3
                }
                let initialCollections = await rig.provider.count
                let initialProbes = await rig.prober.count
                t.expectEqual(initialCollections, 1)
                t.expectEqual(initialProbes, 3)

                await rig.clock.advance(20)
                try await waitUntil { await rig.provider.count == 2 }
                let nextCollections = await rig.provider.count
                let probesAfterLocal = await rig.prober.count
                t.expectEqual(nextCollections, 2)
                t.expectEqual(probesAfterLocal, 3)

                await rig.clock.advance(100)
                try await waitUntil { await rig.prober.count == 6 }
                let probesAfterLight = await rig.prober.count
                t.expectEqual(probesAfterLight, 6)
                await rig.stop()
            },
            TestCase("连续三轮失败、4xx 不计失败、网络宽限重置计数") { t in
                let rig = try await RuntimeRig(category: .timeout)
                await rig.start()
                try await waitUntil { await rig.prober.count == 3 }
                await rig.clock.advance(120)
                try await waitUntil { await rig.prober.count == 6 }
                let failingAfterTwo = await rig.model.overall.faultKeys.contains(.group(.mainland))
                t.expectEqual(failingAfterTwo, false)
                await rig.clock.advance(120)
                try await waitUntil { await rig.model.overall.faultKeys.contains(.group(.mainland)) }
                let severity = await rig.model.overall.severity
                let initialNotices = await rig.notifier.count
                t.expectEqual(severity, .critical)
                t.expectEqual(initialNotices, 1) // 同一轮多故障合并。

                rig.observer.emit(.network)
                try await waitUntil { await rig.model.local?.isInGracePeriod == true }
                let hasGraceEnd = await rig.model.graceEndsAt != nil
                t.expectEqual(hasGraceEnd, true)
                let noticesBeforeGrace = await rig.notifier.count
                await rig.clock.advance(9)
                let noticesDuringGrace = await rig.notifier.count
                t.expectEqual(noticesDuringGrace, noticesBeforeGrace)
                await rig.clock.advance(1)
                try await waitUntil {
                    let ended = await rig.model.local?.isInGracePeriod == false
                    let probed = await rig.prober.count
                    return ended && probed >= 12
                }
                let stillFailing = await rig.model.overall.faultKeys.contains(.group(.mainland))
                let noticesAfterGrace = await rig.notifier.count
                t.expectEqual(stillFailing, false)
                t.expectEqual(noticesAfterGrace, noticesBeforeGrace)

                await rig.prober.setCategory(.restricted)
                await rig.clock.advance(120)
                try await waitUntil { await rig.prober.count >= 15 }
                let failingAfter403 = await rig.model.overall.faultKeys.contains(.group(.mainland))
                t.expectEqual(failingAfter403, false)
                await rig.stop()
            },
            TestCase("设置改变使迟到旧轮次失效；手动全测每站 3 次") { t in
                let rig = try await RuntimeRig(category: .reachable)
                await rig.prober.holdNextBatch()
                await rig.start()
                try await waitUntil { await rig.prober.count == 3 }
                let changed = AppSettings(expectedDNS: ["8.8.8.8"], notificationsEnabled: false, sites: FixtureLoader.legacySites)
                await rig.settingsDidChange(changed)
                await rig.prober.releaseHeld()
                try await waitUntil {
                    let collected = await rig.provider.count
                    let probed = await rig.prober.count
                    return collected >= 2 && probed >= 6
                }
                let appliedSettings = await rig.model.settings
                let localSeverity = await rig.model.local?.severity
                t.expectEqual(appliedSettings, changed)
                t.expectEqual(localSeverity, .critical)

                await rig.recheck()
                try await waitUntil { await rig.prober.count >= 15 }
                try await waitUntil { await rig.model.checkProgress == nil }
                for _ in 0..<20 { await Task.yield() }
                let lateProgress = await rig.model.checkProgress
                t.expectNil(lateProgress)
                let requests = await rig.prober.requests
                let full = requests.suffix(9)
                t.expectEqual(full.count, 9)
                t.expect(full.allSatisfy { $0.attempts == 3 })
                await rig.stop()
            },
            TestCase("宽限内改设置仍在期末复查；睡眠暂停并在唤醒恢复") { t in
                let rig = try await RuntimeRig()
                await rig.start()
                try await waitUntil { await rig.prober.count == 3 }
                rig.observer.emit(.network)
                try await waitUntil { await rig.model.local?.isInGracePeriod == true }
                await rig.settingsDidChange(AppSettings(notificationsEnabled: false, sites: FixtureLoader.legacySites))
                try await waitUntil { await rig.clock.hasSleeper(after: 10) }
                await rig.clock.advance(10)
                try await waitUntil {
                    let ended = await rig.model.graceEndsAt == nil
                    let probed = await rig.prober.count
                    return ended && probed >= 6
                }
                let beforeSleep = await rig.provider.count
                rig.observer.emit(.sleep)
                try await waitUntil { await rig.clock.uptimePendingCount == 1 }
                try await waitUntil { await rig.model.checkProgress == nil }
                await rig.clock.advanceAsleep(240)
                for _ in 0..<20 { await Task.yield() }
                let duringSleep = await rig.provider.count
                t.expectEqual(duringSleep, beforeSleep)
                rig.observer.emit(.wake)
                try await waitUntil { await rig.model.local?.isInGracePeriod == true }
                try await waitUntil { await rig.clock.hasSleeper(after: 10) }
                await rig.clock.advance(10)
                try await waitUntil {
                    let ended = await rig.model.graceEndsAt == nil
                    let probed = await rig.prober.count
                    return ended && probed >= 9
                }
                let afterWake = await rig.provider.count
                t.expect(afterWake > duringSleep)
                await rig.stop()
            },
            TestCase("适配器目录变化后下一轮使用新配置；手动重新加载立即生效") { t in
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("np-runtime-adapters-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let registry = VPNAdapterRegistry(store: VPNAdapterStore(directory: dir.path))
                let rig = try await RuntimeRig(scenario: .b, adapterRegistry: registry)
                await rig.start()
                try await waitUntil {
                    let idle = await rig.model.checkProgress == nil
                    let evaluated = await rig.model.local != nil
                    return idle && evaluated
                }
                let before = await rig.model.local?.vpnState
                t.expect(before != .connected, "没有适配器时不应识别出 VPN 已连接")
                let emptySet = await rig.model.adapterSet
                t.expectEqual(emptySet, VPNAdapterSet())

                let file = dir.appendingPathComponent("example.json")
                try JSONEncoder().encode(FixtureLoader.vpnAdapter).write(to: file)
                try await waitUntil { await rig.clock.hasSleeper(after: 20) }
                await rig.clock.advance(20)
                try await waitUntil { await rig.model.local?.vpnState == .connected }
                let loaded = await rig.model.adapterSet.adapters.map(\.id)
                t.expectEqual(loaded, [FixtureLoader.vpnAdapter.id])

                try FileManager.default.removeItem(at: file)
                let collected = await rig.provider.count
                await rig.controller.reloadAdapters()
                try await waitUntil {
                    let state = await rig.model.local?.vpnState
                    let count = await rig.provider.count
                    return count > collected && state != .connected
                }
                let cleared = await rig.model.adapterSet
                t.expectEqual(cleared, VPNAdapterSet())
                await rig.stop()
            },
            TestCase("故障事件：启动与出现写入日志，宽限期内不记录") { t in
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("np-runtime-events-\(UUID().uuidString).jsonl")
                defer { try? FileManager.default.removeItem(at: url) }
                let store = FaultEventStore(fileURL: url)
                let earlier = FaultEvent(date: Date(timeIntervalSince1970: 1_790_000_000), kind: .started)
                store.append([earlier])

                let rig = try await RuntimeRig(category: .timeout, eventStore: store)
                await rig.start()
                let initial = await rig.model.recentEvents.map(\.kind)
                t.expectEqual(initial, [.started, .started], "启动时载入已有事件，再记录本次启动")

                try await waitUntil { await rig.prober.count == 3 }
                await rig.clock.advance(120)
                try await waitUntil { await rig.prober.count == 6 }
                await rig.clock.advance(120)
                try await waitUntil { await rig.model.overall.faultKeys.contains(.group(.mainland)) }
                try await waitUntil { await rig.model.checkProgress == nil }
                let afterFault = await rig.model.recentEvents
                t.expect(afterFault.contains { $0.kind == .appeared && $0.key == .group(.mainland) })
                t.expectEqual(store.recent().count, afterFault.count, "界面与日志一致")

                rig.observer.emit(.network)
                try await waitUntil { await rig.model.local?.isInGracePeriod == true }
                let beforeGrace = await rig.model.recentEvents.count
                await rig.clock.advance(9)
                for _ in 0..<20 { await Task.yield() }
                let duringGrace = await rig.model.recentEvents.count
                t.expectEqual(duringGrace, beforeGrace)

                // 宽限结束后计数清零，连通性故障消失。
                await rig.prober.setCategory(.reachable)
                await rig.clock.advance(1)
                try await waitUntil {
                    await rig.model.recentEvents.contains { $0.kind == .cleared && $0.key == .group(.mainland) }
                }
                await rig.stop()
            },
        ])
    }

    enum WaitError: Error { case timedOut }

    static func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        throw WaitError.timedOut
    }
}

actor RuntimeVirtualClock {
    private var time = Date(timeIntervalSince1970: 1_790_424_000)
    /// 墙钟与单调时钟的等待者。取消时同步移除，避免已取消的计时器干扰 `hasSleeper` 判断。
    private nonisolated let wall = SleeperBox()
    private nonisolated let monotonic = SleeperBox()
    /// 单调时钟（系统真正睡眠时不走），供睡眠兜底计时使用。
    private var uptime: TimeInterval = 0

    nonisolated func monitorClock() -> MonitorClock {
        MonitorClock(now: { self.currentSync() }, sleep: { seconds in try await self.sleep(seconds) },
                     uptimeSleep: { seconds in try await self.uptimeSleep(seconds) })
    }

    // Date reads are isolated by a lock so the synchronous clock API remains Sendable.
    private nonisolated let dateBox = DateBox(Date(timeIntervalSince1970: 1_790_424_000))
    private nonisolated func currentSync() -> Date { dateBox.get() }

    func sleep(_ seconds: TimeInterval) async throws {
        try await wall.wait(until: time.timeIntervalSince1970 + seconds)
    }

    func uptimeSleep(_ seconds: TimeInterval) async throws {
        try await monotonic.wait(until: uptime + seconds)
    }

    /// 系统醒着时经过的时间：墙钟和单调时钟都前进。
    func advance(_ seconds: TimeInterval) {
        uptime += seconds
        monotonic.resume(through: uptime)
        advanceAsleep(seconds)
    }

    /// 系统真正睡眠期间经过的时间：只有墙钟前进，单调时钟不走。
    func advanceAsleep(_ seconds: TimeInterval) {
        time = time.addingTimeInterval(seconds)
        dateBox.set(time)
        wall.resume(through: time.timeIntervalSince1970)
    }

    var pendingCount: Int { wall.count }
    var uptimePendingCount: Int { monotonic.count }
    func hasSleeper(after seconds: TimeInterval) -> Bool {
        wall.contains(deadline: time.timeIntervalSince1970 + seconds)
    }
}

/// 可取消的虚拟等待队列：任务取消时同步移除并抛出 CancellationError。
private final class SleeperBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    private var cancelled: Set<UUID> = []

    func wait(until deadline: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in add(id, deadline, continuation) }
        } onCancel: {
            cancel(id)
        }
    }

    private func add(_ id: UUID, _ deadline: TimeInterval, _ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled.remove(id) != nil {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        sleepers[id] = (deadline, continuation)
        lock.unlock()
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        let entry = sleepers.removeValue(forKey: id)
        if entry == nil { cancelled.insert(id) }
        lock.unlock()
        entry?.1.resume(throwing: CancellationError())
    }

    func resume(through now: TimeInterval) {
        lock.lock()
        let ready = sleepers.filter { $0.value.0 <= now }
        for id in ready.keys { sleepers[id] = nil }
        lock.unlock()
        for (_, entry) in ready { entry.1.resume() }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return sleepers.count }

    func contains(deadline: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.values.contains { abs($0.0 - deadline) < 0.001 }
    }
}

private final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func get() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: Date) { lock.lock(); value = next; lock.unlock() }
}

actor RuntimeSnapshotStub: LocalSnapshotProviding {
    let snapshot: LocalSnapshot
    private(set) var count = 0
    init(_ snapshot: LocalSnapshot) { self.snapshot = snapshot }
    func collectSnapshot() async -> LocalSnapshot { count += 1; return snapshot }
}

actor RuntimeProberStub: SiteProbing {
    struct Request: Sendable { let id: String; let attempts: Int }
    private var category: ProbeCategory
    private(set) var requests: [Request] = []
    private var held = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var count: Int { requests.count }

    init(category: ProbeCategory) { self.category = category }
    func setCategory(_ category: ProbeCategory) { self.category = category }
    func holdNextBatch() { held = true }
    func releaseHeld() {
        held = false
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }
    func probe(site: Site, attempts: Int, timeout: TimeInterval) async -> SiteResult {
        requests.append(Request(id: site.id, attempts: attempts))
        if held { await withCheckedContinuation { continuations.append($0) } }
        let outcomes = (0..<attempts).map { _ -> RequestOutcome in
            switch category {
            case .reachable: return .http(status: 204, latency: 0.01)
            case .restricted: return .http(status: 403, latency: 0.01)
            default: return .failure(category)
            }
        }
        return SiteAggregator.aggregate(site: site, outcomes: outcomes, checkedAt: Date())
    }
}

final class RuntimeObserverStub: NetworkChangeObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (NetworkChangeEvent) -> Void)?
    func start(handler: @escaping @Sendable (NetworkChangeEvent) -> Void) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    func stop() { lock.lock(); handler = nil; lock.unlock() }
    func emit(_ reason: NetworkChangeReason) {
        lock.lock(); let callback = handler; lock.unlock()
        callback?(NetworkChangeEvent(reason: reason, date: Date()))
    }
}

actor RuntimeNotifierStub: UserNotifying {
    private(set) var sent: [PendingNotification] = []
    var count: Int { sent.count }
    func requestAuthorization() async -> Bool { true }
    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func deliver(_ notification: PendingNotification) async { sent.append(notification) }
}

@MainActor
final class RuntimeRig {
    let model: AppModel
    let clock = RuntimeVirtualClock()
    let provider: RuntimeSnapshotStub
    let prober: RuntimeProberStub
    let observer = RuntimeObserverStub()
    let notifier = RuntimeNotifierStub()
    let controller: MonitorController

    init(category: ProbeCategory = .reachable, settings: AppSettings = FixtureLoader.legacySettings,
         scenario: FixtureLoader.Scenario = .a, adapterRegistry: VPNAdapterRegistry? = nil,
         eventStore: FaultEventStore? = nil, diagnoser: SiteDiagnosing? = nil) async throws {
        let snapshot = try FixtureLoader.snapshot(scenario)
        provider = RuntimeSnapshotStub(snapshot)
        prober = RuntimeProberStub(category: category)
        model = AppModel(settings: settings, notificationAuthorization: .authorized)
        controller = MonitorController(model: model, snapshotProvider: provider, prober: prober,
                                       observer: observer, notifier: notifier, paths: FixtureLoader.paths,
                                       adapters: FixtureLoader.adapterSet,
                                       adapterRegistry: adapterRegistry,
                                       eventStore: eventStore,
                                       diagnoser: diagnoser,
                                       clock: clock.monitorClock())
    }
    func start() { controller.start() }
    func stop() { controller.stop() }
    func recheck() { controller.recheck() }
    func settingsDidChange(_ settings: AppSettings) { controller.settingsDidChange(settings) }
}
