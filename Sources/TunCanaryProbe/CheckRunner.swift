import Foundation
@preconcurrency import TunCanaryCore

/// 只能触发一次 resume 的门闩，供“工作任务 vs 整体超时”竞速使用。
private final class ResumeOnceVerdict: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// 整体超时竞速中共享的阶段性结果：超时时据此保留已完成的本机评估和站点结果。
private final class PartialCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var firstLocal: LocalAssessment?
    private var secondLocal: LocalAssessment?
    private var sites: [Site] = []
    private var intranet: IntranetProbeDecision = .notConfigured
    private var tailnet: TailnetProbeDecision = .notConfigured
    private var results: [Int: SiteResult] = [:]

    func setFirstLocal(_ local: LocalAssessment) { locked { firstLocal = local } }
    func setSecondLocal(_ local: LocalAssessment) { locked { secondLocal = local } }
    func setPlan(sites: [Site], intranet: IntranetProbeDecision, tailnet: TailnetProbeDecision) {
        locked {
            self.sites = sites
            self.intranet = intranet
            self.tailnet = tailnet
        }
    }
    func record(_ result: SiteResult, at index: Int) { locked { results[index] = result } }

    /// 按已完成的部分生成超时判定；未完成的站点按原顺序列出。
    func timedOutVerdict(full: Bool, checkedAt: Date, configuredSites: [Site]) -> CLIVerdict {
        lock.lock()
        defer { lock.unlock() }
        let done = sites.indices.compactMap { results[$0] }
        let pending = sites.indices.filter { results[$0] == nil }.map { sites[$0] }
        return CLIVerdict.timedOut(firstLocal: firstLocal, secondLocal: secondLocal, siteResults: done,
                                   incompleteSites: pending, intranet: intranet, tailnet: tailnet, full: full,
                                   checkedAt: checkedAt, configuredSites: configuredSites)
    }

    private func locked(_ body: () -> Void) {
        lock.lock()
        body()
        lock.unlock()
    }
}

/// `--check` 单次编排：本机检查（黄或红时等 10 秒复采一次）与站点探测并发执行，整体超时 30 秒。
///
/// 站点全部并发探测：轻测每站最多 2 次、完整检测每站 3 次，单次 4 秒，最坏约 8 秒或 12 秒，与站点数无关。
/// 超时时保留已完成的本机评估和站点结果，未完成的站点不计为失败。
///
/// 时间与随机性全部通过注入的 `now`/`sleep` 提供，测试可以让 `sleep` 立即返回，从而不真的等待
/// 10 秒或 30 秒。`now`/`sleep` 的类型都标了 `@Sendable`，可以安全地跨 Task 使用。
public struct CheckRunner: Sendable {
    public typealias NowProvider = @Sendable () -> Date
    public typealias SleepFunction = @Sendable (TimeInterval) async -> Void

    private let snapshotProvider: LocalSnapshotProviding
    private let prober: SiteProbing
    private let settings: AppSettings
    private let evaluator: LocalEvaluator
    private let now: NowProvider
    private let sleep: SleepFunction

    /// - Parameters:
    ///   - snapshotProvider: 本机快照采集（`SystemSnapshotProvider`，或测试桩）。
    ///   - prober: 站点探测（`URLSessionSiteProber`，或测试桩）。
    ///   - settings: 应用设置（内网 URL、预期 DNS 等）。
    ///   - paths: 构造 `LocalEvaluator` 用的已知路径，默认取当前用户。
    ///   - adapters: VPN 适配器配置，须与 `snapshotProvider` 使用的一致。
    ///   - now: 当前时间，默认 `Date.init`；测试可注入固定时钟。
    ///   - sleep: 睡眠函数，默认真的 `Task.sleep`；测试可注入立即返回的假实现。
    public init(
        snapshotProvider: LocalSnapshotProviding,
        prober: SiteProbing,
        settings: AppSettings,
        paths: KnownPaths = .currentUser(),
        adapters: VPNAdapterSet = VPNAdapterSet(),
        now: @escaping NowProvider = { Date() },
        sleep: @escaping SleepFunction = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        }
    ) {
        self.snapshotProvider = snapshotProvider
        self.prober = prober
        self.settings = settings
        self.evaluator = LocalEvaluator(paths: paths, adapterSet: adapters)
        self.now = now
        self.sleep = sleep
    }

    /// 执行一次 `--check`。整体超时 `PulseConstants.cliOverallTimeout` 秒，超时时返回保留部分结果的判定。
    public func run(options: CheckOptions) async -> CLIVerdict {
        let gate = ResumeOnceVerdict()
        let partial = PartialCheck()
        let configuredSites = settings.enabledSites
        return await withCheckedContinuation { (continuation: CheckedContinuation<CLIVerdict, Never>) in
            let workTask = Task {
                let verdict = await performCheck(options: options, partial: partial)
                if gate.claim() {
                    continuation.resume(returning: verdict)
                }
            }
            Task {
                await sleep(PulseConstants.cliOverallTimeout)
                if gate.claim() {
                    workTask.cancel()
                    continuation.resume(returning: partial.timedOutVerdict(
                        full: options.full, checkedAt: now(), configuredSites: configuredSites))
                }
            }
        }
    }

    // MARK: - 编排

    private func performCheck(options: CheckOptions, partial: PartialCheck) async -> CLIVerdict {
        let firstSnapshot = await snapshotProvider.collectSnapshot()
        let firstLocal = evaluator.evaluate(snapshot: firstSnapshot, settings: settings, inGracePeriod: false)
        partial.setFirstLocal(firstLocal)

        // 内网探测决策取自第一次评估的 VPN 状态与设置。
        let intranet = SiteCatalog.intranetDecision(intranetURL: settings.intranetURL,
                                                    vpnState: firstLocal.vpnState)
        // 家庭子网决策取自第一次评估的路由判断。
        let tailnet = firstLocal.tailnetDecision
        let sites = options.full
            ? SiteCatalog.fullCheckSites(intranet: intranet, tailnet: tailnet, sites: settings.sites)
            : SiteCatalog.lightProbeSites(intranet: intranet, tailnet: tailnet, sites: settings.sites)
        partial.setPlan(sites: sites, intranet: intranet, tailnet: tailnet)

        // 复查本机（黄或红时）与站点探测并发进行。
        async let secondLocal = recheckIfNeeded(firstLocal: firstLocal, partial: partial)
        async let probed = probeSites(sites, full: options.full, partial: partial)

        let second = await secondLocal
        let siteResults = await probed

        return CLIVerdict.make(
            firstLocal: firstLocal,
            secondLocal: second,
            siteResults: siteResults,
            intranet: intranet,
            tailnet: tailnet,
            full: options.full,
            checkedAt: now(),
            configuredSites: settings.enabledSites
        )
    }

    /// 本机结果为黄或红时，等待 10 秒后再采一次并评估；否则不复采。
    private func recheckIfNeeded(firstLocal: LocalAssessment, partial: PartialCheck) async -> LocalAssessment? {
        guard firstLocal.severity.isAlerting else { return nil }
        await sleep(PulseConstants.cliRecheckDelay)
        guard !Task.isCancelled else { return nil }
        let snapshot = await snapshotProvider.collectSnapshot()
        let second = evaluator.evaluate(snapshot: snapshot, settings: settings, inGracePeriod: false)
        partial.setSecondLocal(second)
        return second
    }

    /// 全部站点并发探测，结果按输入顺序返回；每完成一站即记入 `partial`，供超时时保留。
    private func probeSites(_ sites: [Site], full: Bool, partial: PartialCheck) async -> [SiteResult] {
        guard !sites.isEmpty else { return [] }
        var results = [SiteResult?](repeating: nil, count: sites.count)
        await withTaskGroup(of: (Int, SiteResult).self) { group in
            for (index, site) in sites.enumerated() {
                group.addTask {
                    let result = full
                        ? await prober.probe(site: site, attempts: PulseConstants.fullProbeAttempts,
                                             timeout: PulseConstants.probeTimeout)
                        : await probeLightSite(site)
                    partial.record(result, at: index)
                    return (index, result)
                }
            }
            for await (index, result) in group { results[index] = result }
        }
        return results.compactMap { $0 }
    }

    /// 轻测中的一个站点。关键站点最多请求 2 次：先 1 次，计为失败再补 1 次；两次都失败才算失败。
    /// 4xx 不计失败，因此不会触发第二次请求。非关键站点只请求 1 次。
    private func probeLightSite(_ site: Site) async -> SiteResult {
        guard site.isKey else {
            return await prober.probe(site: site, attempts: PulseConstants.lightProbeAttempts, timeout: PulseConstants.probeTimeout)
        }
        let first = await prober.probe(site: site, attempts: 1, timeout: PulseConstants.probeTimeout)
        guard first.isFailure, !Task.isCancelled else { return first }
        let second = await prober.probe(site: site, attempts: 1, timeout: PulseConstants.probeTimeout)
        return SiteAggregator.aggregate(site: site, outcomes: first.attempts + second.attempts, checkedAt: now())
    }
}
