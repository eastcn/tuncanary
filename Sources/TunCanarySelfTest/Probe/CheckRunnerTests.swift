import Foundation
import TunCanaryCore
import TunCanaryProbe

/// 依次返回一组预设快照的假 `LocalSnapshotProviding`：耗尽后重复最后一个。
private final class QueueSnapshotProvider: LocalSnapshotProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [LocalSnapshot]
    private(set) var callCount = 0

    init(_ snapshots: [LocalSnapshot]) {
        queue = snapshots
    }

    func collectSnapshot() async -> LocalSnapshot {
        next()
    }

    /// 用普通同步方法包一层：`NSLock` 不应直接在 `async` 函数体内加锁/解锁。
    private func next() -> LocalSnapshot {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        if queue.count > 1 { return queue.removeFirst() }
        return queue.first!
    }
}

/// 按站点 id 预先编排每次调用应返回的结果的假 `SiteProbing`：每次 `probe` 调用消费脚本中的
/// 下一个 `RequestOutcome`（`attempts` 份相同的结果，因为 CLI 轻测总是以 `attempts: 1` 调用）。
/// 耗尽后重复最后一个。
private final class ScriptedProber: SiteProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String: [RequestOutcome]]
    private var cursor: [String: Int] = [:]
    private var counts: [String: Int] = [:]

    init(scripts: [String: [RequestOutcome]]) {
        self.scripts = scripts
    }

    func callCount(for siteID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[siteID] ?? 0
    }

    var probedSiteIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(counts.keys)
    }

    func probe(site: Site, attempts: Int, timeout: TimeInterval) async -> SiteResult {
        let outcome = nextOutcome(for: site.id)
        let outcomes = Array(repeating: outcome, count: max(attempts, 1))
        return SiteAggregator.aggregate(site: site, outcomes: outcomes, checkedAt: Date())
    }

    /// 用普通同步方法包一层：`NSLock` 不应直接在 `async` 函数体内加锁/解锁。
    private func nextOutcome(for siteID: String) -> RequestOutcome {
        lock.lock()
        defer { lock.unlock() }
        let list = scripts[siteID] ?? [.http(status: 200, latency: 0.01)]
        let idx = cursor[siteID, default: 0]
        let outcome = list[min(idx, list.count - 1)]
        cursor[siteID] = idx + 1
        counts[siteID, default: 0] += 1
        return outcome
    }
}

/// 永不返回的假探测器（直到外部任务被取消），用于制造整体超时。
private struct HangingProber: SiteProbing {
    func probe(site: Site, attempts: Int, timeout: TimeInterval) async -> SiteResult {
        try? await Task.sleep(nanoseconds: UInt64.max / 4)
        return SiteAggregator.aggregate(site: site, outcomes: [], checkedAt: Date())
    }
}

/// 记录同时在途的探测数；每次探测等到 `expected` 个同时在途或 0.3 秒后返回可达。
private final class ConcurrencyProber: SiteProbing, @unchecked Sendable {
    private let lock = NSLock()
    private let expected: Int
    private var inFlight = 0
    private(set) var maxInFlight = 0

    init(expected: Int) { self.expected = expected }

    func probe(site: Site, attempts: Int, timeout: TimeInterval) async -> SiteResult {
        enter()
        for _ in 0..<60 where current() < expected {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        leave()
        let outcomes = Array(repeating: RequestOutcome.http(status: 204, latency: 0.01), count: max(attempts, 1))
        return SiteAggregator.aggregate(site: site, outcomes: outcomes, checkedAt: Date())
    }

    var observedMax: Int { lock.lock(); defer { lock.unlock() }; return maxInFlight }
    private func current() -> Int { lock.lock(); defer { lock.unlock() }; return inFlight }
    private func enter() { lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock() }
    private func leave() { lock.lock(); inFlight -= 1; lock.unlock() }
}

/// 指定站点永不返回（直到取消），其余站点按脚本立即返回；记录已完成的站点数。
private final class PartlyHangingProber: SiteProbing, @unchecked Sendable {
    private let lock = NSLock()
    private let hanging: Set<String>
    private let failing: Set<String>
    private var done = 0

    init(hanging: Set<String>, failing: Set<String> = []) {
        self.hanging = hanging
        self.failing = failing
    }

    var completed: Int { lock.lock(); defer { lock.unlock() }; return done }

    func probe(site: Site, attempts: Int, timeout: TimeInterval) async -> SiteResult {
        if hanging.contains(site.id) {
            try? await Task.sleep(nanoseconds: UInt64.max / 4)
            return SiteAggregator.aggregate(site: site, outcomes: [], checkedAt: Date())
        }
        let outcome: RequestOutcome = failing.contains(site.id) ? .failure(.timeout) : .http(status: 204, latency: 0.02)
        finish()
        return SiteAggregator.aggregate(site: site, outcomes: Array(repeating: outcome, count: max(attempts, 1)),
                                        checkedAt: Date())
    }

    private func finish() { lock.lock(); done += 1; lock.unlock() }
}

/// 快照采集永不返回（直到取消），用于“没有任何结论”的超时。
private struct HangingSnapshotProvider: LocalSnapshotProviding {
    let snapshot: LocalSnapshot
    func collectSnapshot() async -> LocalSnapshot {
        try? await Task.sleep(nanoseconds: UInt64.max / 4)
        return snapshot
    }
}

enum CheckRunnerTests {
    typealias F = FixtureLoader

    /// 大多数用例使用：10 秒复采延迟立即返回；30 秒整体超时不应该真的触发，
    /// 用一个极长的睡眠代替（工作流程应远早于它完成），避免这两条测试路径产生竞态。
    static let normalSleep: CheckRunner.SleepFunction = { seconds in
        if seconds >= PulseConstants.cliOverallTimeout {
            try? await Task.sleep(nanoseconds: UInt64.max / 4)
        }
    }

    /// 超时用例专用：30 秒整体超时立即触发。
    static let immediateTimeoutSleep: CheckRunner.SleepFunction = { _ in }

    /// 整体超时在 `ready` 满足后（再留 50 ms 让在途结果落盘）才触发；10 秒复采立即返回。
    static func timeoutSleep(after ready: @escaping @Sendable () -> Bool) -> CheckRunner.SleepFunction {
        { seconds in
            guard seconds >= PulseConstants.cliOverallTimeout else { return }
            for _ in 0..<400 where !ready() { try? await Task.sleep(nanoseconds: 5_000_000) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func runner(
        snapshots: [LocalSnapshot],
        prober: SiteProbing,
        settings: AppSettings = F.legacySettings,
        sleep: @escaping CheckRunner.SleepFunction = normalSleep
    ) -> (CheckRunner, QueueSnapshotProvider) {
        let provider = QueueSnapshotProvider(snapshots)
        let runner = CheckRunner(
            snapshotProvider: provider, prober: prober, settings: settings, paths: F.paths, adapters: F.adapterSet,
            now: { F.collectedAt }, sleep: sleep
        )
        return (runner, provider)
    }

    static var suite: TestSuite {
        TestSuite("Probe.CheckRunner", [
            TestCase("自定义站点：轻测选择后台项，完整检测不含禁用项") { t in
                let custom = Site(id: "custom", name: "自定义", group: .overseas,
                                  url: URL(string: "https://custom.example/health")!, isKey: true, inLightProbe: true)
                let manual = Site(id: "manual", name: "手动", group: .overseas,
                                  url: URL(string: "https://manual.example/")!, isKey: false, inLightProbe: false)
                var disabled = SiteCatalog.baidu
                disabled.isEnabled = false
                let settings = AppSettings(sites: [custom, manual, disabled])
                let lightProber = ScriptedProber(scripts: ["custom": [.failure(.timeout)]])
                let (light, _) = runner(snapshots: [try F.snapshot(.a)], prober: lightProber, settings: settings)
                let verdict = await light.run(options: CheckOptions())
                t.expectEqual(Set(lightProber.probedSiteIDs), ["custom"])
                t.expectEqual(lightProber.callCount(for: "custom"), 2)
                t.expectEqual(verdict.exitCode, .critical, "该组唯一后台站点失败时应判为组故障")

                let fullProber = ScriptedProber(scripts: [:])
                let (full, _) = runner(snapshots: [try F.snapshot(.a)], prober: fullProber, settings: settings)
                let fullVerdict = await full.run(options: CheckOptions(full: true))
                t.expectEqual(Set(fullProber.probedSiteIDs), ["custom", "manual"])
                t.expectEqual(fullVerdict.siteResults.count, 2)
                let redactor = Redactor(siteURLs: [custom.url])
                t.expectNotContains(redactor.redact("错误 \(custom.url.absoluteString)（custom.example）"), "custom.example")
            },
            TestCase("空站点配置不回退到默认探测目录") { t in
                let prober = ScriptedProber(scripts: [:])
                let (check, _) = runner(snapshots: [try F.snapshot(.a)], prober: prober,
                                        settings: AppSettings(sites: []))
                let result = await check.run(options: CheckOptions(full: true))
                t.expectEqual(result.siteResults.count, 0)
                t.expectEqual(prober.probedSiteIDs.count, 0)
                t.expectEqual(result.exitCode, .ok)
            },
            TestCase("A 组 + 轻测全部正常 → 绿色，不复采") { t in
                let snapshot = try F.snapshot(.a)
                let prober = ScriptedProber(scripts: [:]) // 默认全部成功
                let (runner, provider) = runner(snapshots: [snapshot], prober: prober)
                let verdict = await runner.run(options: CheckOptions())
                t.expectEqual(verdict.exitCode, .ok)
                t.expect(verdict.localConfirmed)
                t.expectEqual(provider.callCount, 1, "本机结果为绿色时不应复采")
            },
            TestCase("本机黄色两次一致 → 需关注，且确实复采了一次") { t in
                var bypass = try F.snapshot(.a)
                bypass.mihomoDNS = .noResponse(port: 7874)
                let prober = ScriptedProber(scripts: [:])
                let (runner, provider) = runner(snapshots: [bypass, bypass], prober: prober)
                let verdict = await runner.run(options: CheckOptions())
                t.expectEqual(verdict.exitCode, .warning)
                t.expect(verdict.localConfirmed)
                t.expectEqual(provider.callCount, 2, "黄色应等待 10 秒后复采一次")
            },
            TestCase("本机两次采样不一致 → 未确认") { t in
                var bypass = try F.snapshot(.a)
                bypass.mihomoDNS = .noResponse(port: 7874)
                let cSnapshot = try F.snapshot(.c)
                let prober = ScriptedProber(scripts: [:])
                let (runner, _) = runner(snapshots: [bypass, cSnapshot], prober: prober)
                let verdict = await runner.run(options: CheckOptions())
                t.expectEqual(verdict.exitCode, .unconfirmed)
                t.expect(!verdict.localConfirmed)
            },
            TestCase("C 组两次一致 → 故障（红）") { t in
                let snapshot = try F.snapshot(.c)
                let prober = ScriptedProber(scripts: [:])
                let (runner, provider) = runner(snapshots: [snapshot, snapshot], prober: prober)
                let verdict = await runner.run(options: CheckOptions())
                t.expectEqual(verdict.exitCode, .critical)
                t.expect(verdict.localConfirmed)
                t.expectEqual(provider.callCount, 2)
            },
            TestCase("关键站点首次失败、重试成功 → 不计为失败") { t in
                let snapshot = try F.snapshot(.a)
                let prober = ScriptedProber(scripts: [
                    "google": [.failure(.timeout), .http(status: 200, latency: 0.05)],
                ])
                let (runner, _) = runner(snapshots: [snapshot], prober: prober)
                let verdict = await runner.run(options: CheckOptions())
                t.expectEqual(verdict.exitCode, .ok)
                t.expectEqual(prober.callCount(for: "google"), 2, "首次失败应补一次请求")
                t.expectEqual(prober.callCount(for: "baidu"), 1)
                t.expectEqual(prober.callCount(for: "claude"), 1)
            },
            TestCase("关键站点两次都失败 → 计为失败") { t in
                let snapshot = try F.snapshot(.a)
                let prober = ScriptedProber(scripts: [
                    "google": [.failure(.timeout), .failure(.dnsFailure)],
                ])
                let (runner, _) = runner(snapshots: [snapshot], prober: prober)
                let verdict = await runner.run(options: CheckOptions())
                t.expectEqual(verdict.exitCode, .warning)
                t.expectEqual(prober.callCount(for: "google"), 2)
            },
            TestCase("4xx 不计为失败，也不重试") { t in
                let snapshot = try F.snapshot(.a)
                let prober = ScriptedProber(scripts: [
                    "claude": [.http(status: 403, latency: 0.02)],
                ])
                let (runner, _) = runner(snapshots: [snapshot], prober: prober)
                let verdict = await runner.run(options: CheckOptions())
                t.expectEqual(verdict.exitCode, .ok)
                t.expectEqual(prober.callCount(for: "claude"), 1, "4xx 不应触发第二次请求")
            },
            TestCase("内网探测决策：已连接时参与轻测") { t in
                let snapshot = try F.snapshot(.b)
                let local = F.evaluate(snapshot)
                t.expectEqual(local.vpnState, .connected, "fixture B 场景应为已连接")
                let settings = AppSettings(intranetURL: URL(string: "https://intranet.corp.example/health")!)
                let prober = ScriptedProber(scripts: [:])
                let (runner, _) = runner(snapshots: [snapshot], prober: prober, settings: settings)
                let verdict = await runner.run(options: CheckOptions())
                t.expect(verdict.intranet.site != nil, "已连接且已配置时应参与探测")
                t.expect(prober.probedSiteIDs.contains(SiteCatalog.intranetID))
            },
            TestCase("内网探测决策：未连接时不探测") { t in
                let snapshot = try F.snapshot(.a)
                let local = F.evaluate(snapshot)
                t.expectEqual(local.vpnState, .disconnected, "fixture A 场景应为已断开")
                let settings = AppSettings(intranetURL: URL(string: "https://intranet.corp.example/health")!)
                let prober = ScriptedProber(scripts: [:])
                let (runner, _) = runner(snapshots: [snapshot], prober: prober, settings: settings)
                let verdict = await runner.run(options: CheckOptions())
                t.expectEqual(verdict.intranet, .vpnDisconnected)
                t.expect(!prober.probedSiteIDs.contains(SiteCatalog.intranetID))
            },
            TestCase("内网探测决策：未配置时未验证") { t in
                let snapshot = try F.snapshot(.b)
                let prober = ScriptedProber(scripts: [:])
                let (runner, _) = runner(snapshots: [snapshot], prober: prober) // 默认设置无内网 URL
                let verdict = await runner.run(options: CheckOptions())
                t.expectEqual(verdict.intranet, .notConfigured)
                t.expect(!prober.probedSiteIDs.contains(SiteCatalog.intranetID))
            },
            TestCase("整体超时 30 秒 → 未确认（退出码 3）", timeout: 5) { t in
                let snapshot = try F.snapshot(.a) // 绿色，不需要复采，探测阶段会一直挂起
                let prober = HangingProber()
                let (runner, _) = runner(snapshots: [snapshot], prober: prober, sleep: immediateTimeoutSleep)
                let start = Date()
                let verdict = await runner.run(options: CheckOptions())
                let elapsed = Date().timeIntervalSince(start)
                t.expectEqual(verdict.exitCode, .unconfirmed)
                t.expect(verdict.timedOut)
                t.expect(elapsed < 3, "超时应尽快返回，而不是真的等待（实际 \(elapsed) 秒）")
            },
            TestCase("--full：使用完整站点目录与并发探测") { t in
                let snapshot = try F.snapshot(.a)
                let prober = ScriptedProber(scripts: [:])
                let (runner, _) = runner(snapshots: [snapshot], prober: prober)
                let verdict = await runner.run(options: CheckOptions(full: true))
                t.expectEqual(verdict.exitCode, .ok)
                t.expectEqual(verdict.siteResults.count, FixtureLoader.legacySites.count)
                t.expect(verdict.full)
            },
            TestCase("H2：轻测所有站点并发，--full 默认 9 站同时在途", timeout: 10) { t in
                let keys = (1...4).map { index in
                    Site(id: "key\(index)", name: "关键\(index)", group: .overseas,
                         url: URL(string: "https://key\(index).example/")!, isKey: true, inLightProbe: true)
                }
                let light = ConcurrencyProber(expected: 4)
                let (lightRunner, _) = runner(snapshots: [try F.snapshot(.a)], prober: light,
                                              settings: AppSettings(sites: keys))
                let lightVerdict = await lightRunner.run(options: CheckOptions())
                t.expectEqual(lightVerdict.exitCode, .ok)
                t.expectEqual(light.observedMax, 4, "轻测应并发探测全部站点，最坏耗时与站点数无关")

                let full = ConcurrencyProber(expected: FixtureLoader.legacySites.count)
                let (fullRunner, _) = runner(snapshots: [try F.snapshot(.a)], prober: full)
                let fullVerdict = await fullRunner.run(options: CheckOptions(full: true))
                t.expectEqual(fullVerdict.siteResults.count, FixtureLoader.legacySites.count)
                t.expectEqual(full.observedMax, FixtureLoader.legacySites.count, "默认 9 站应一次并发完成")
            },
            TestCase("H2：整体超时保留已确认的本机红色结论（退出码 2）", timeout: 10) { t in
                let snapshot = try F.snapshot(.c)
                let provider = QueueSnapshotProvider([snapshot, snapshot])
                let check = CheckRunner(snapshotProvider: provider, prober: HangingProber(), settings: F.legacySettings,
                                        paths: F.paths, adapters: F.adapterSet, now: { F.collectedAt },
                                        sleep: timeoutSleep { provider.callCount >= 2 })
                let verdict = await check.run(options: CheckOptions())
                t.expect(verdict.timedOut)
                t.expectEqual(verdict.exitCode, .critical, "DNS 未恢复已确认，超时不应丢掉红色结论")
                t.expect(verdict.localConfirmed)
                let text = verdict.renderText(redactor: Redactor())
                t.expectContains(text, "DNS 未恢复")
                t.expectContains(text, "[未确认] 检查超时（30 秒），未完成：百度、Google、Claude（不计为失败）")
                t.expectContains(text, "未完成（超时）")
                t.expectContains(text, "Google")
                let json = verdict.renderJSON(redactor: Redactor())
                t.expectContains(json, "\"timedOut\" : true")
                t.expectContains(json, "\"incompleteSites\"")
                t.expectContains(json, "\"google\"")
            },
            TestCase("H2：超时时已完成站点保留，未完成站点不计失败", timeout: 10) { t in
                let prober = PartlyHangingProber(hanging: ["google"], failing: ["baidu"])
                let (check, _) = runner(snapshots: [try F.snapshot(.a)], prober: prober,
                                        sleep: timeoutSleep { prober.completed >= 2 })
                let verdict = await check.run(options: CheckOptions())
                t.expect(verdict.timedOut)
                t.expectEqual(Set(verdict.siteResults.map(\.site.id)), ["baidu", "claude"])
                t.expectEqual(verdict.exitCode, .critical, "百度两次失败已确认为国内出口故障")
                t.expect(!verdict.faults.contains { $0.key == .site("google") }, "未完成的站点不计为失败")
                let text = verdict.renderText(redactor: Redactor())
                t.expectContains(text, "Google 未完成（超时）")
            },
            TestCase("H2：--full 超时保留已完成站点，JSON 列出未完成站点", timeout: 10) { t in
                let prober = PartlyHangingProber(hanging: ["google", "github"])
                let (check, _) = runner(snapshots: [try F.snapshot(.a)], prober: prober,
                                        sleep: timeoutSleep { prober.completed >= 7 })
                let verdict = await check.run(options: CheckOptions(full: true))
                t.expect(verdict.timedOut)
                t.expectEqual(verdict.siteResults.count, 7)
                t.expectEqual(verdict.exitCode, .unconfirmed, "关键站点未完成、其余正常时不能判为正常")
                let text = verdict.renderText(redactor: Redactor())
                t.expectContains(text, "Google 未完成（超时）")
                t.expectContains(text, "GitHub 未完成（超时）")
                let json = verdict.renderJSON(redactor: Redactor())
                t.expectContains(json, "\"github\"")
                t.expectContains(json, "\"incompleteSites\"")
            },
            TestCase("H2：本机与站点均未完成时退出码 3", timeout: 10) { t in
                let check = CheckRunner(snapshotProvider: HangingSnapshotProvider(snapshot: try F.snapshot(.a)),
                                        prober: HangingProber(), settings: F.legacySettings, paths: F.paths,
                                        adapters: F.adapterSet,
                                        now: { F.collectedAt }, sleep: immediateTimeoutSleep)
                let verdict = await check.run(options: CheckOptions())
                t.expect(verdict.timedOut)
                t.expectEqual(verdict.exitCode, .unconfirmed)
                t.expectContains(verdict.renderText(redactor: Redactor()), "超时")
            },
        ])
    }
}
