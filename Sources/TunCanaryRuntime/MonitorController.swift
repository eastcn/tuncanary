import Foundation
import TunCanaryCore
import TunCanaryProbe
import TunCanaryUI

/// 调度器使用的时间源。测试可注入虚拟时钟，无须等待真实的 20/120 秒。
public struct MonitorClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async throws -> Void
    /// 睡眠兜底计时用的单调时钟：系统真正睡眠时不走。未指定时沿用 `sleep`。
    public var uptimeSleep: @Sendable (TimeInterval) async throws -> Void

    public init(now: @escaping @Sendable () -> Date,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
                uptimeSleep: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.now = now
        self.sleep = sleep
        self.uptimeSleep = uptimeSleep ?? sleep
    }

    public static let live = MonitorClock(
        now: { Date() },
        sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) },
        uptimeSleep: { seconds in
            try await Task.sleep(until: .now + .milliseconds(Int64(max(0, seconds) * 1000)),
                                 clock: SuspendingClock())
        })
}

/// 菜单栏应用的检查调度。所有可见状态与告警计数只在主 actor 提交。
@MainActor
public final class MonitorController {
    private enum CheckKind: Int, Comparable {
        case local = 0
        case light = 1
        case full = 2

        static func < (lhs: CheckKind, rhs: CheckKind) -> Bool { lhs.rawValue < rhs.rawValue }

        var progressKind: CheckProgress.Kind {
            switch self {
            case .local: return .local
            case .light: return .light
            case .full: return .full
            }
        }
    }

    public let model: AppModel
    private let snapshotProvider: LocalSnapshotProviding
    private let prober: SiteProbing
    private let observer: NetworkChangeObserving
    private let notifier: UserNotifying
    private var evaluator: LocalEvaluator
    private let paths: KnownPaths
    /// 菜单栏应用中的适配器集合；为 nil 时始终使用初始化时传入的 `adapters`。
    private let adapterRegistry: VPNAdapterRegistry?
    private let clock: MonitorClock
    private var activeSettings: AppSettings

    private var running = false
    private var sleeping = false
    private var generation = 0
    private var nextRunToken = 0
    private var progressRunToken: Int?
    private var activeTask: Task<Void, Never>?
    private var queuedCheck: CheckKind?
    private var localTimer: Task<Void, Never>?
    private var lightTimer: Task<Void, Never>?
    private var graceTimer: Task<Void, Never>?
    private var sleepFallback: Task<Void, Never>?
    private var grace = GraceTracker()
    private var tracker = ConnectivityTracker()
    private var deduper = NotificationDeduper()
    private var recorder = FaultEventRecorder()
    /// 故障事件日志；为 nil 时只在内存中保留最近事件。
    private let eventStore: FaultEventStore?

    public init(model: AppModel,
                snapshotProvider: LocalSnapshotProviding,
                prober: SiteProbing,
                observer: NetworkChangeObserving,
                notifier: UserNotifying,
                paths: KnownPaths = .currentUser(),
                adapters: VPNAdapterSet = VPNAdapterSet(),
                adapterRegistry: VPNAdapterRegistry? = nil,
                eventStore: FaultEventStore? = nil,
                clock: MonitorClock = .live) {
        self.model = model
        self.snapshotProvider = snapshotProvider
        self.prober = prober
        self.observer = observer
        self.notifier = notifier
        self.paths = paths
        self.adapterRegistry = adapterRegistry
        self.eventStore = eventStore
        let initialAdapters = adapterRegistry?.current ?? adapters
        self.evaluator = LocalEvaluator(paths: paths, adapterSet: initialAdapters)
        self.clock = clock
        model.adapterSet = initialAdapters
        self.activeSettings = model.settings
    }

    public func start() {
        guard !running else { return }
        running = true
        sleeping = false
        recorder = FaultEventRecorder()
        if let eventStore { model.recentEvents = eventStore.recent(limit: AppModel.recentEventLimit) }
        record([FaultEvent(date: clock.now(), kind: .started)])
        observer.start { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
        startTimers()
        enqueue(.light)
        Task { [weak self] in
            guard let self else { return }
            let status = await self.notifier.authorizationStatus()
            guard self.running else { return }
            self.model.notificationAuthorization = status
            if status == .notDetermined {
                _ = await self.notifier.requestAuthorization()
                guard self.running else { return }
                self.model.notificationAuthorization = await self.notifier.authorizationStatus()
            }
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        generation += 1
        observer.stop()
        cancelTimers()
        graceTimer?.cancel()
        graceTimer = nil
        cancelSleepFallback()
        activeTask?.cancel()
        queuedCheck = nil
        model.checkProgress = nil
        progressRunToken = nil
        model.graceEndsAt = nil
    }

    /// 界面“立即复测”：本机检查 + 全部站点，每站 3 次，最多 3 站并发。
    /// 用户能操作界面说明已唤醒；漏收唤醒事件时由此恢复调度。
    public func recheck() {
        resumeFromSleep()
        enqueue(.full)
    }

    /// 界面“重新加载 VPN 适配器”：不比对目录指纹，强制重新读取，并立即做一次本机检查。
    public func reloadAdapters() {
        guard let adapterRegistry else { return }
        applyAdapters(adapterRegistry.reload())
        resumeFromSleep()
        generation += 1
        activeTask?.cancel()
        queuedCheck = nil
        model.checkProgress = nil
        progressRunToken = nil
        enqueue(.local)
    }

    private func applyAdapters(_ adapters: VPNAdapterSet) {
        evaluator = LocalEvaluator(paths: paths, adapterSet: adapters)
        model.adapterSet = adapters
    }

    /// 设置保存后复查；版本递增使旧设置下完成的结果失效。
    public func settingsDidChange(_ settings: AppSettings) {
        let previous = activeSettings
        activeSettings = settings
        model.settings = settings
        // 保存设置说明已唤醒；下面统一重建定时器。
        if sleeping {
            sleeping = false
            cancelSleepFallback()
        }
        generation += 1
        activeTask?.cancel()
        queuedCheck = nil
        model.checkProgress = nil
        progressRunToken = nil
        // 只清零探测目标实际改变的站点；改名、改组和预期 DNS 不影响可达性计数。
        var retargeted = Self.retargetedSiteIDs(previous: previous.sites, current: settings.sites)
        if settings.intranetURL != previous.intranetURL { retargeted.insert(SiteCatalog.intranetID) }
        if settings.tailnetTarget != previous.tailnetTarget { retargeted.insert(SiteCatalog.tailnetID) }
        tracker.reset(siteIDs: retargeted)
        retainCurrentHistory(settings: settings, previous: previous)
        // 取消旧周期，使保存后的下一次后台检查使用新间隔。
        cancelTimers()
        if running { startTimers() }
        model.intranetDecision = SiteCatalog.intranetDecision(intranetURL: settings.intranetURL,
                                                              vpnState: .unconfirmed)
        model.tailnetDecision = settings.tailnetTarget == nil ? .notConfigured : .unconfirmed
        restoreGraceIfNeeded()
        enqueue(.light)
    }

    private func startTimers() {
        localTimer = timer(every: model.settings.effectiveLocalCheckInterval, kind: .local)
        lightTimer = timer(every: model.settings.effectiveLightProbeInterval, kind: .light)
    }

    private func timer(every interval: TimeInterval, kind: CheckKind) -> Task<Void, Never> {
        Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(interval) } catch { break }
                guard !Task.isCancelled, let self, self.running, !self.sleeping else { break }
                self.enqueue(kind)
            }
        }
    }

    private func cancelTimers() {
        localTimer?.cancel()
        lightTimer?.cancel()
        localTimer = nil
        lightTimer = nil
    }

    private func handle(_ event: NetworkChangeEvent) {
        guard running else { return }
        if event.reason == .sleep {
            sleeping = true
            generation += 1
            activeTask?.cancel()
            queuedCheck = nil
            cancelTimers()
            graceTimer?.cancel()
            graceTimer = nil
            model.graceEndsAt = nil
            model.checkProgress = nil
            progressRunToken = nil
            startSleepFallback()
            return
        }

        if sleeping {
            sleeping = false
            cancelSleepFallback()
            startTimers()
        }
        generation += 1
        activeTask?.cancel()
        queuedCheck = nil
        model.checkProgress = nil
        progressRunToken = nil
        _ = grace.noteChange(event.reason, at: clock.now())
        model.graceEndsAt = grace.graceEndsAt
        // 立即采集一轮切换中状态；宽限结束后重新采集并补轻测。
        enqueue(.local)
        scheduleGraceEnd()
    }

    /// 漏收唤醒事件时恢复调度：重建定时器，仍在宽限期内则重新安排期末复查。
    private func resumeFromSleep() {
        guard running, sleeping else { return }
        sleeping = false
        cancelSleepFallback()
        startTimers()
        restoreGraceIfNeeded()
    }

    private func restoreGraceIfNeeded() {
        guard running, !sleeping, grace.isInGracePeriod(at: clock.now()) else { return }
        model.graceEndsAt = grace.graceEndsAt
        scheduleGraceEnd()
    }

    /// 进入睡眠后按单调时钟兜底：真正睡眠时该时钟不走，到点说明其实没有睡着，自动恢复。
    private func startSleepFallback() {
        sleepFallback?.cancel()
        sleepFallback = Task { [weak self, clock] in
            do { try await clock.uptimeSleep(PulseConstants.sleepFallbackDelay) } catch { return }
            guard !Task.isCancelled, let self, self.running, self.sleeping else { return }
            self.resumeFromSleep()
            self.enqueue(.light)
        }
    }

    private func cancelSleepFallback() {
        sleepFallback?.cancel()
        sleepFallback = nil
    }

    private func scheduleGraceEnd() {
        graceTimer?.cancel()
        guard let end = grace.graceEndsAt else { return }
        let version = generation
        let delay = max(0, end.timeIntervalSince(clock.now()))
        graceTimer = Task { [weak self, clock] in
            do { try await clock.sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.running, !self.sleeping,
                  self.generation == version else { return }
            self.model.graceEndsAt = nil
            self.tracker.reset()
            self.generation += 1
            self.activeTask?.cancel()
            self.queuedCheck = nil
            self.model.checkProgress = nil
            self.progressRunToken = nil
            self.enqueue(.light)
        }
    }

    private func enqueue(_ kind: CheckKind) {
        guard running, !sleeping else { return }
        if activeTask != nil {
            queuedCheck = max(queuedCheck ?? kind, kind)
            return
        }
        let version = generation
        nextRunToken += 1
        let token = nextRunToken
        progressRunToken = token
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.perform(kind, version: version, token: token)
            self.activeTask = nil
            if let next = self.queuedCheck {
                self.queuedCheck = nil
                self.enqueue(next)
            }
        }
    }

    private func perform(_ kind: CheckKind, version: Int, token: Int) async {
        defer {
            if progressRunToken == token {
                progressRunToken = nil
                model.checkProgress = nil
            }
        }
        guard isCurrent(version) else { return }
        model.checkProgress = CheckProgress(kind: kind.progressKind)
        // 适配器目录有变化时重新加载；采集读取同一个 registry，本轮即使用新配置。
        if let reloaded = adapterRegistry?.reloadIfChanged() {
            applyAdapters(reloaded)
        }
        let settings = model.settings
        let snapshot = await snapshotProvider.collectSnapshot()
        guard isCurrent(version) else { return }
        let inGrace = grace.isInGracePeriod(at: clock.now())
        let local = evaluator.evaluate(snapshot: snapshot, settings: settings, inGracePeriod: inGrace)
        let decision = SiteCatalog.intranetDecision(intranetURL: settings.intranetURL,
                                                    vpnState: local.vpnState)
        model.intranetDecision = decision
        let tailnet = local.tailnetDecision
        model.tailnetDecision = tailnet
        if decision.site == nil || tailnet.site == nil {
            // 不满足条件的内网站点和家庭子网：计数清零，历史清除。
            tracker.recordRound([], intranetEligible: decision.site != nil, tailnetEligible: tailnet.site != nil)
            clearConditionalHistory(intranet: decision.site == nil, tailnet: tailnet.site == nil)
        }

        var results: [SiteResult] = []
        if kind != .local && !inGrace {
            let sites = kind == .full
                ? SiteCatalog.fullCheckSites(intranet: decision, tailnet: tailnet, sites: settings.sites)
                : SiteCatalog.lightProbeSites(intranet: decision, tailnet: tailnet, sites: settings.sites)
            model.checkProgress = CheckProgress(kind: kind.progressKind, completed: 0, total: sites.count)
            results = await ProbeBatch(prober: prober).run(
                sites: sites,
                attempts: kind == .full ? PulseConstants.fullProbeAttempts : PulseConstants.lightProbeAttempts,
                timeout: PulseConstants.probeTimeout,
                progress: { [weak self] completed, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrent(version),
                              self.progressRunToken == token else { return }
                        self.model.checkProgress = CheckProgress(kind: kind.progressKind,
                                                                 completed: completed, total: total)
                    }
                })
            guard isCurrent(version), results.count == sites.count else { return }
            model.siteHistory.record(results)
            tracker.recordRound(results, intranetEligible: decision.site != nil, tailnetEligible: tailnet.site != nil)
        }

        guard isCurrent(version) else { return }
        let eligibleSites = settings.enabledSites + (decision.site.map { [$0] } ?? []) + (tailnet.site.map { [$0] } ?? [])
        let faults = inGrace ? [] : tracker.faults(sites: eligibleSites)
        model.apply(local: local, connectivityFaults: faults, checkedAt: clock.now())
        guard !inGrace else { return }
        record(recorder.update(with: model.overall.faults, at: clock.now(), redactor: model.redactor))
        let pending = deduper.update(with: model.overall.faults, redactor: model.redactor)
        if settings.notificationsEnabled,
           let notification = NotificationMerger.merge(pending),
           model.notificationAuthorization == .authorized,
           isCurrent(version) {
            await notifier.deliver(notification)
        }
    }

    /// 写入事件日志，并更新界面上的最近事件。
    private func record(_ events: [FaultEvent]) {
        guard !events.isEmpty else { return }
        eventStore?.append(events)
        model.recentEvents = Array((model.recentEvents + events).suffix(AppModel.recentEventLimit))
    }

    private func isCurrent(_ version: Int) -> Bool {
        running && !sleeping && version == generation && !Task.isCancelled
    }

    private func clearConditionalHistory(intranet: Bool, tailnet: Bool) {
        var retained = SiteHistory(limit: model.siteHistory.limit)
        for (id, results) in model.siteHistory.results {
            if intranet && id == SiteCatalog.intranetID { continue }
            if tailnet && id == SiteCatalog.tailnetID { continue }
            retained.record(results)
        }
        model.siteHistory = retained
    }

    /// 同一 ID 的 URL 或探测方式改变后，旧结果不能冒充新目标的历史；改名、改组保留历史并改用新名称。
    private func retainCurrentHistory(settings: AppSettings, previous: AppSettings) {
        var retained = SiteHistory(limit: model.siteHistory.limit)
        // 站点 ID 重复时取第一个，与探测和告警的处理一致，也避免构造字典时崩溃。
        let currentSites = Dictionary(settings.enabledSites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, results) in model.siteHistory.results {
            if id == SiteCatalog.intranetID {
                if settings.intranetURL == previous.intranetURL { retained.record(results) }
            } else if id == SiteCatalog.tailnetID {
                if settings.tailnetTarget == previous.tailnetTarget { retained.record(results) }
            } else if let site = currentSites[id] {
                retained.record(results.filter { Self.sameProbeTarget($0.site, site) }.map { result in
                    var renamed = result
                    renamed.site = site
                    return renamed
                })
            }
        }
        model.siteHistory = retained
    }

    /// 探测目标是否相同：id、URL、启用状态和参与后台检测开关。名称和分组不影响探测。
    private static func sameProbeTarget(_ lhs: Site, _ rhs: Site) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url && lhs.isEnabled == rhs.isEnabled
            && lhs.isKey == rhs.isKey && lhs.inLightProbe == rhs.inLightProbe
    }

    /// 探测目标改变、被删除或新加入的站点 ID；只有这些站点需要清零连续失败计数。
    private static func retargetedSiteIDs(previous: [Site], current: [Site]) -> Set<String> {
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids = Set<String>()
        for (id, old) in previousByID {
            if let new = currentByID[id], sameProbeTarget(old, new) { continue }
            ids.insert(id)
        }
        for id in currentByID.keys where previousByID[id] == nil { ids.insert(id) }
        return ids
    }
}
