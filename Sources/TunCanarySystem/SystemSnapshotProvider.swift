import Foundation
import TunCanaryCore

/// 一轮采集中的各项，用于记录耗时。
public enum SnapshotItem: String, Sendable, CaseIterable {
    case clashConfig
    case processes
    case interfaces
    case routes
    case resolvers
    case dynamicStore
    case vpnStatusFiles
    case mihomoDNS
    case canary
}

/// 一轮采集的结果与耗时（秒），供诊断与性能核对。
public struct SnapshotCollectionReport: Sendable {
    public var snapshot: LocalSnapshot
    /// 整轮耗时。
    public var totalDuration: TimeInterval
    /// 各项耗时。并发执行，所以总耗时约等于最慢一项（Mihomo DNS 排在配置读取之后）。
    public var itemDurations: [SnapshotItem: TimeInterval]
}

/// 由真实系统数据填充 `LocalSnapshot`。
///
/// - 各项并发采集：阻塞调用都放在 GCD 全局队列上，不占用 Swift 并发的协作线程。
/// - 只读命令 `netstat -rn -f inet`、`scutil --dns` 每轮各调用一次，超时 3 秒。
/// - Mihomo DNS 查询在读完 Clash 配置后发起（需要端口），超时 2 秒；系统解析 canary 超时 3 秒。
/// - 不抛错：每项失败写进快照对应字段。
/// - 值类型，可在任意线程并发调用；canary 的“上一次未返回不再发起”状态在副本之间共享。
public struct SystemSnapshotProvider: LocalSnapshotProviding, Sendable {
    public struct Configuration: Sendable {
        public var paths: KnownPaths
        /// VPN 适配器配置：决定匹配哪些进程、读取哪些状态文件。
        public var adapters: [VPNAdapterConfig]
        /// 每轮采集开始时取当前的代理来源（设置可能在运行中改变）。
        public var proxySource: @Sendable () -> ProxySource
        /// 只读命令超时（秒）。
        public var commandTimeout: TimeInterval
        /// Mihomo DNS 查询超时（秒）。
        public var mihomoDNSTimeout: TimeInterval
        /// Mihomo DNS 地址。
        public var mihomoDNSHost: String
        /// 系统解析 canary 的超时（秒）。域名每轮取自 `proxySource`，代理 DNS 也查询同一个域名。
        public var canaryTimeout: TimeInterval
        /// 是否执行系统解析 canary（测试中可关闭，避免访问网络）。
        public var resolvesCanary: Bool
        /// 是否查询 Mihomo DNS。
        public var probesMihomoDNS: Bool

        public init(
            paths: KnownPaths = .currentUser(),
            adapters: [VPNAdapterConfig] = [],
            proxySource: @escaping @Sendable () -> ProxySource = { ProxySource() },
            commandTimeout: TimeInterval = PulseConstants.commandTimeout,
            mihomoDNSTimeout: TimeInterval = PulseConstants.mihomoDNSTimeout,
            mihomoDNSHost: String = PulseConstants.mihomoDNSHost,
            canaryTimeout: TimeInterval = PulseConstants.commandTimeout,
            resolvesCanary: Bool = true,
            probesMihomoDNS: Bool = true
        ) {
            self.paths = paths
            self.adapters = adapters
            self.proxySource = proxySource
            self.commandTimeout = commandTimeout
            self.mihomoDNSTimeout = mihomoDNSTimeout
            self.mihomoDNSHost = mihomoDNSHost
            self.canaryTimeout = canaryTimeout
            self.resolvesCanary = resolvesCanary
            self.probesMihomoDNS = probesMihomoDNS
        }
    }

    public static let netstatPath = "/usr/sbin/netstat"
    public static let netstatArguments = ["-rn", "-f", "inet"]
    public static let scutilPath = "/usr/sbin/scutil"
    public static let scutilArguments = ["--dns"]

    public let configuration: Configuration
    private let now: @Sendable () -> Date
    private let matcher: RelevantProcessMatcher
    private let runner: CommandRunner
    private let canary: SystemResolverCanary

    /// - Parameters:
    ///   - configuration: 路径、超时与开关，默认使用当前用户和计划中的超时。
    ///   - now: 采集时间来源（写入 `collectedAt`），测试可注入。
    public init(configuration: Configuration = Configuration(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.now = now
        self.matcher = RelevantProcessMatcher(paths: configuration.paths, adapters: configuration.adapters)
        self.runner = CommandRunner()
        self.canary = SystemResolverCanary(timeout: configuration.canaryTimeout)
    }

    /// 以指定路径、适配器和代理来源创建（其余取默认值）。
    public init(paths: KnownPaths, adapters: [VPNAdapterConfig] = [],
                proxySource: @escaping @Sendable () -> ProxySource = { ProxySource() }) {
        self.init(configuration: Configuration(paths: paths, adapters: adapters, proxySource: proxySource))
    }

    public func collectSnapshot() async -> LocalSnapshot {
        await collectReport().snapshot
    }

    /// 采集一轮并返回各项耗时。
    public func collectReport() async -> SnapshotCollectionReport {
        let collectedAt = now()
        let started = Monotonic.now()
        let config = configuration
        let matcher = self.matcher
        let runner = self.runner
        let source = config.proxySource()
        let coreName = source.client == .manual ? ClashConfig.manual(source.manual).coreProcessName : nil

        async let clashTask = Blocking.timed { Self.readProxyConfig(config.paths, source: source) }
        async let processTask = Blocking.timed {
            Self.collectProcesses(matcher, extraNames: coreName.map { [$0] } ?? [])
        }
        async let interfaceTask = Blocking.timed { Self.collectInterfaces() }
        async let routeTask = Blocking.timed { Self.collectRoutes(runner, timeout: config.commandTimeout) }
        async let resolverTask = Blocking.timed { Self.collectResolvers(runner, timeout: config.commandTimeout) }
        async let storeTask = Blocking.timed { DynamicStoreReader().read() }
        async let statusTask = Blocking.timed { Self.collectVPNStatusFiles(config) }
        async let canaryTask = resolveCanary(host: source.canaryHost)

        // Mihomo DNS 依赖配置中的端口，读完配置后立即发起，与其余各项并行。
        let (clashConfig, clashDuration) = await clashTask
        let mihomoStart = Monotonic.now()
        let mihomo = await probeMihomo(clashConfig, queryName: source.canaryHost)
        let mihomoDuration = Monotonic.now() - mihomoStart

        let (processes, processDuration) = await processTask
        let (interfaces, interfaceDuration) = await interfaceTask
        let (routes, routeDuration) = await routeTask
        let (resolvers, resolverDuration) = await resolverTask
        let (store, storeDuration) = await storeTask
        let (statusFiles, statusDuration) = await statusTask
        let (canaryResult, canaryDuration) = await canaryTask

        let snapshot = LocalSnapshot(
            collectedAt: collectedAt,
            clashConfig: clashConfig,
            mihomoRunning: source.client == .manual
                ? (coreName.map { name in processes.map { list in list.contains { $0.executableName == name } } }
                    ?? .notCollected)
                : processes.map { list in list.contains { $0.executableName == KnownPaths.mihomoProcessName } },
            processes: processes,
            interfaces: interfaces,
            routes: routes,
            resolvers: resolvers,
            vpnStatusFiles: statusFiles,
            primaryService: store.primaryService,
            globalDNS: store.globalDNS,
            mihomoDNS: mihomo,
            canary: canaryResult,
            canaryHost: source.canaryHost
        )
        return SnapshotCollectionReport(
            snapshot: snapshot,
            totalDuration: Monotonic.now() - started,
            itemDurations: [
                .clashConfig: clashDuration,
                .processes: processDuration,
                .interfaces: interfaceDuration,
                .routes: routeDuration,
                .resolvers: resolverDuration,
                .dynamicStore: storeDuration,
                .vpnStatusFiles: statusDuration,
                .mihomoDNS: mihomoDuration,
                .canary: canaryDuration,
            ]
        )
    }

    // MARK: - 各项采集

    /// 代理配置：Clash Verge Rev 读取配置文件；手动模式直接由设置构造。
    static func readProxyConfig(_ paths: KnownPaths, source: ProxySource) -> Collected<ClashConfig> {
        switch source.client {
        case .clashVergeRev: return ClashConfigReader(paths: paths).read()
        case .manual: return .collected(ClashConfig.manual(source.manual))
        }
    }

    static func collectProcesses(_ matcher: RelevantProcessMatcher, extraNames: [String] = []) -> Collected<[ProcessEntry]> {
        do {
            return .collected(try ProcessScanner().relevantProcesses(matcher: matcher, extraNames: extraNames))
        } catch let error as SystemCollectionError {
            return .failed(reason: error.message)
        } catch {
            return .failed(reason: "进程列表读取失败")
        }
    }

    /// 读取配置了状态文件的各适配器，键为适配器 ID。
    static func collectVPNStatusFiles(_ config: Configuration) -> [String: VPNStatusFileState] {
        var result: [String: VPNStatusFileState] = [:]
        for adapter in config.adapters {
            guard let fields = adapter.statusFile,
                  let path = adapter.statusFilePath(home: config.paths.homeDirectory) else { continue }
            result[adapter.id] = VPNStatusFileReader(path: path, fields: fields).read()
        }
        return result
    }

    static func collectInterfaces() -> Collected<[InterfaceInfo]> {
        do {
            return .collected(try InterfaceScanner().scan())
        } catch let error as SystemCollectionError {
            return .failed(reason: error.message)
        } catch {
            return .failed(reason: "网络接口读取失败")
        }
    }

    static func collectRoutes(_ runner: CommandRunner, timeout: TimeInterval) -> Collected<[RouteEntry]> {
        let result = runner.run(netstatPath, netstatArguments, timeout: timeout)
        if let reason = result.failureReason(name: "netstat", timeout: timeout) {
            return .failed(reason: reason)
        }
        return .collected(NetstatRouteParser.parse(result.outputText))
    }

    static func collectResolvers(_ runner: CommandRunner, timeout: TimeInterval) -> Collected<[Resolver]> {
        let result = runner.run(scutilPath, scutilArguments, timeout: timeout)
        if let reason = result.failureReason(name: "scutil --dns", timeout: timeout) {
            return .failed(reason: reason)
        }
        return .collected(ScutilDNSParser.parse(result.outputText))
    }

    /// 查询 Mihomo DNS。配置不可读时为 `.notCollected`；TUN 配置关闭或没有端口时为 `.notApplicable`。
    func probeMihomo(_ clashConfig: Collected<ClashConfig>, queryName: String) async -> MihomoDNSProbeResult {
        guard configuration.probesMihomoDNS else { return .notCollected }
        guard let config = clashConfig.value else { return .notCollected }
        guard let port = Self.mihomoPort(for: config) else { return .notApplicable }
        let prober = MihomoDNSProber(
            host: configuration.mihomoDNSHost,
            queryName: queryName,
            timeout: configuration.mihomoDNSTimeout
        )
        return await prober.probe(port: port)
    }

    /// 应查询的端口：TUN 配置关闭或配置中没有 `dns.listen` 端口时为 nil。
    public static func mihomoPort(for config: ClashConfig) -> Int? {
        if config.tunConfigured == false { return nil }
        return config.dnsListenPort
    }

    private func resolveCanary(host: String) async -> (CanaryResult, TimeInterval) {
        guard configuration.resolvesCanary else { return (.notTested, 0) }
        let start = Monotonic.now()
        let result = await canary.resolve(host: host)
        return (result, Monotonic.now() - start)
    }
}
