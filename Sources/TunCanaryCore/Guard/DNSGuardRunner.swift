import Foundation

// DNS 守护进程一次运行的编排。采样、写入、读回和探针都通过协议注入，测试中用桩对象，不改系统 DNS。

/// 采集一次样本（实现见 TunCanarySystem）。
public protocol DNSGuardSampling: Sendable {
    func sample() async -> DNSGuardSample
}

/// 写入前复读的结果、写入结果和读回结果。
public enum DNSGuardWriteOutcome: Sendable, Equatable {
    case written
    /// 写入前复读发现保存值已变化，放弃写入。
    case changed(String)
    case failed(String)
}

/// 读回：主服务、保存的 DNS 和系统默认解析器。读不到的项为 nil。
public struct DNSGuardReadBack: Sendable, Equatable {
    public var primaryServiceID: String?
    public var savedDNS: [String]?
    public var resolverDNS: [String]?

    public init(primaryServiceID: String?, savedDNS: [String]?, resolverDNS: [String]?) {
        self.primaryServiceID = primaryServiceID
        self.savedDNS = savedDNS.map { DNSList.normalize($0) }
        self.resolverDNS = resolverDNS.map { DNSList.normalize($0) }
    }
}

/// 写入保存的 DNS（实现见 TunCanarySystem，基于 SCPreferences）。
public protocol DNSGuardWriting: Sendable {
    /// 加锁后复读服务的保存值，与 `plan.currentDNS` 一致才写入，只替换 `ServerAddresses`。
    func write(_ plan: DNSGuardWritePlan) -> DNSGuardWriteOutcome
    func readBack(serviceID: String) -> DNSGuardReadBack
}

/// 通过代理 DNS 查询内网探针。
public protocol DNSGuardProbing: Sendable {
    func probe(host: String, port: Int) async -> DNSGuardProbeResult
}

/// 状态文件与事件日志的读写。
public protocol DNSGuardStateStoring: Sendable {
    func loadState() -> DNSGuardState
    func saveState(_ state: DNSGuardState) throws
    func appendEvent(_ event: DNSGuardEvent) throws
}

/// 一次运行的结果。
public struct DNSGuardRunReport: Sendable, Equatable {
    public var decision: DNSGuardDecision
    public var event: DNSGuardEvent
    /// 是否实际调用了写入。
    public var attemptedWrite: Bool
    /// 保存状态或事件失败的原因。
    public var storageProblem: String?
}

public struct DNSGuardRunner: Sendable {
    /// 连续失败多少次后退避。
    public static let failureThreshold = 3
    public static let backoffDuration: TimeInterval = 600
    /// 读回的次数与间隔：写入后系统需要一点时间把新值同步到 `Setup:` 层和解析器。
    public static let readBackAttempts = 5
    public static let readBackInterval: TimeInterval = 1
    /// 两次采样显示 VPN 正在切换时，在同一次运行里重新采样的次数与间隔。
    /// 切换刚结束就能写入，不必等下一次定时运行。
    public static let transitionRetries = 3
    public static let transitionRetryInterval: TimeInterval = 5
    /// 内网探针失败时重查的次数与间隔。VPN 刚连上的几秒里代理可能还查不到内网域名。
    public static let probeRetries = 3
    public static let probeRetryInterval: TimeInterval = 5

    public var config: DNSGuardConfig
    public var sampler: DNSGuardSampling
    public var writer: DNSGuardWriting
    public var prober: DNSGuardProbing
    public var store: DNSGuardStateStoring
    public var redactor: Redactor
    /// 只判定，不写入，不更新状态文件和事件日志。
    public var dryRun: Bool
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async -> Void

    public init(config: DNSGuardConfig, sampler: DNSGuardSampling, writer: DNSGuardWriting, prober: DNSGuardProbing,
                store: DNSGuardStateStoring, redactor: Redactor = Redactor(), dryRun: Bool = false,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                }) {
        self.config = config
        self.sampler = sampler
        self.writer = writer
        self.prober = prober
        self.store = store
        self.redactor = redactor
        self.dryRun = dryRun
        self.now = now
        self.sleep = sleep
    }

    public func run() async -> DNSGuardRunReport {
        var state = store.loadState()
        var first = await sampler.sample()
        await sleep(config.sampleDelaySeconds)
        var second = await sampler.sample()
        // 切换中：用上一次的第二个样本和新样本重新比较。仍然要求两次一致才写。
        for _ in 0..<Self.transitionRetries where DNSGuardDecider.isTransition(first, second) {
            await sleep(Self.transitionRetryInterval)
            first = second
            second = await sampler.sample()
        }

        // 两次采样 VPN 都已断开：解除连接期接管的停用，清空连接期写入记录。
        if first.vpn == .disconnected && second.vpn == .disconnected {
            state.connectedTakeoverSuspended = false
            state.connectedWrites = []
        }

        var decision = DNSGuardDecider.decide(first: first, second: second, config: config, state: state, now: now())
        if case .needsProbe(let host, let port) = decision {
            for attempt in 0...Self.probeRetries {
                if attempt > 0 { await sleep(Self.probeRetryInterval) }
                let result = await prober.probe(host: host, port: port)
                decision = DNSGuardDecider.decide(first: first, second: second, config: config, state: state,
                                                  probe: result, now: now())
                // 带着探针结果再判定，只会得到写入或探针失败。探针通过就不再重查。
                guard case .skip = decision else { break }
            }
        }

        var attempted = false
        let event: DNSGuardEvent
        switch decision {
        case .skip(let phase, let reason):
            event = makeEvent(phase, .skipped, reason)
        case .needsProbe:
            // 探针已经执行过，不会再次要求；按跳过处理以防万一。
            event = makeEvent(.connected, .skipped, "内网探针未完成")
        case .compliant(let phase):
            state.consecutiveFailures = 0
            event = makeEvent(phase, .compliant, nil)
        case .backoff(let phase, let until):
            event = makeEvent(phase, .backoff, "\(DateText.format(until)) 前不再写入")
        case .suspendTakeover:
            state.connectedTakeoverSuspended = true
            event = makeEvent(.connected, .takeoverSuspended,
                              "10 分钟内已写入 \(config.connectedTakeover.maxWritesPerTenMinutes) 次")
        case .write(let plan):
            if dryRun {
                event = makeEvent(plan.phase, .skipped,
                                  "试运行：将把 \(DNSList.display(plan.currentDNS)) 改为 \(DNSList.display(plan.targetDNS))")
            } else {
                attempted = true
                event = await write(plan, state: &state)
            }
        }

        guard !dryRun else {
            return DNSGuardRunReport(decision: decision, event: event, attemptedWrite: false, storageProblem: nil)
        }
        let shouldLog = attempted || event.outcome == .takeoverSuspended || !Self.sameResult(event, state.lastRun)
        state.lastRun = event
        if attempted { state.lastWrite = event }
        var problem: String?
        do {
            if shouldLog { try store.appendEvent(event) }
            try store.saveState(state)
        } catch {
            problem = "\(error)"
        }
        return DNSGuardRunReport(decision: decision, event: event, attemptedWrite: attempted, storageProblem: problem)
    }

    /// 写前复读、写入、读回，并更新失败计数。
    private func write(_ plan: DNSGuardWritePlan, state: inout DNSGuardState) async -> DNSGuardEvent {
        let before = writer.readBack(serviceID: plan.serviceID)
        guard before.primaryServiceID == plan.serviceID else {
            return makeEvent(plan.phase, .skipped, "写入前复读发现主网络服务已变化，放弃写入")
        }
        guard let saved = before.savedDNS, DNSList.sameSet(saved, plan.currentDNS) else {
            return makeEvent(plan.phase, .skipped, "写入前复读发现保存的 DNS 已变化，放弃写入")
        }

        let outcome = writer.write(plan)
        if case .changed(let reason) = outcome {
            return makeEvent(plan.phase, .skipped, reason)
        }
        // 连接期每次实际写入都计数，无论成败：用来发现与 VPN 客户端互相覆盖。
        if plan.phase == .connected { state.connectedWrites.append(now()) }
        let failure: DNSGuardEvent
        switch outcome {
        case .changed:
            return makeEvent(plan.phase, .skipped, nil)
        case .failed(let reason):
            failure = makeEvent(plan.phase, .writeFailed, reason)
        case .written:
            var last = DNSGuardReadBack(primaryServiceID: nil, savedDNS: nil, resolverDNS: nil)
            for attempt in 0..<Self.readBackAttempts {
                if attempt > 0 { await sleep(Self.readBackInterval) }
                last = writer.readBack(serviceID: plan.serviceID)
                if Self.verified(last, target: plan.targetDNS) {
                    state.consecutiveFailures = 0
                    state.backoffUntil = nil
                    return makeEvent(plan.phase, .written, nil)
                }
            }
            failure = makeEvent(plan.phase, .verifyFailed, Self.readBackProblem(last, target: plan.targetDNS))
        }
        state.consecutiveFailures += 1
        if state.consecutiveFailures >= Self.failureThreshold {
            state.backoffUntil = now().addingTimeInterval(Self.backoffDuration)
        }
        return failure
    }

    static func verified(_ readBack: DNSGuardReadBack, target: [String]) -> Bool {
        guard let saved = readBack.savedDNS, let resolver = readBack.resolverDNS else { return false }
        return DNSList.sameSet(saved, target) && DNSList.sameSet(resolver, target)
    }

    static func readBackProblem(_ readBack: DNSGuardReadBack, target: [String]) -> String {
        guard let saved = readBack.savedDNS else { return "读回失败：无法读取保存的 DNS" }
        guard DNSList.sameSet(saved, target) else { return "读回的保存值为 \(DNSList.display(saved))" }
        guard let resolver = readBack.resolverDNS else { return "读回失败：无法读取系统默认解析器" }
        return "系统默认解析器为 \(DNSList.display(resolver))"
    }

    /// 与上一次结果相同（阶段、结果、原因）时不重复记事件，只更新状态文件。
    public static func sameResult(_ event: DNSGuardEvent, _ previous: DNSGuardEvent?) -> Bool {
        guard let previous else { return false }
        return previous.phase == event.phase && previous.outcome == event.outcome && previous.reason == event.reason
    }

    private func makeEvent(_ phase: DNSGuardPhase?, _ outcome: DNSGuardOutcome, _ reason: String?) -> DNSGuardEvent {
        DNSGuardEvent(date: now(), phase: phase, outcome: outcome, reason: reason.map(redactor.redact))
    }
}

/// 状态文件与事件日志（root 所有，普通用户只读）。与 `FaultEventStore` 一样属于 Core 中的 I/O。
public struct DNSGuardStateStore: DNSGuardStateStoring {
    public static let maxEvents = 200

    public let paths: DNSGuardPaths

    public init(paths: DNSGuardPaths = DNSGuardPaths()) {
        self.paths = paths
    }

    /// 文件不存在或无法解析时从空状态开始。
    public func loadState() -> DNSGuardState {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.stateFile)),
              let state = try? DNSGuardFileParser.parseState(data) else { return DNSGuardState() }
        return state
    }

    public func saveState(_ state: DNSGuardState) throws {
        try write(DNSGuardFileParser.encoder().encode(state), to: paths.stateFile)
    }

    /// 追加一条，只保留最近 `maxEvents` 条。无法解码的旧行被丢弃。
    public func appendEvent(_ event: DNSGuardEvent) throws {
        let url = URL(fileURLWithPath: paths.eventLogFile)
        var events: [DNSGuardEvent] = []
        if let data = try? Data(contentsOf: url) {
            events = DNSGuardFileParser.parseEvents(data, limit: Self.maxEvents)
        }
        events.append(event)
        let encoder = DNSGuardFileParser.encoder()
        var data = Data()
        for item in events.suffix(Self.maxEvents) {
            data.append(try encoder.encode(item))
            data.append(0x0A)
        }
        try write(data, to: paths.eventLogFile)
    }

    /// 原子替换，权限 0644。
    private func write(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }
}
