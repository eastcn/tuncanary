import AppKit
import Foundation
import Network
import TunCanaryCore
import SystemConfiguration

/// 监听网络变化、睡眠与唤醒。
///
/// 事件来源：
/// - SCDynamicStore 通知：全局 IPv4 与 DNS、各服务保存与生效的 DNS、utun 接口的 IPv4。
/// - `NWPathMonitor`：路径状态或可用接口变化（首次回调是初始状态，忽略）。
/// - `NSWorkspace.willSleepNotification` / `didWakeNotification`。
///
/// 去抖规则见 `ChangeDebouncer`：网络变化与唤醒 2 秒去抖，事件时间取第一次变化；睡眠立即回调。
///
/// 线程与并发：
/// - 内部状态与各事件源都在私有串行队列上处理；`start`、`stop` 可在任意线程（含回调内）反复调用。
/// - 回调在另一个私有串行队列上按顺序执行（“任意线程”）。`stop` 返回后不会再开始新的回调，
///   但已在执行中的一次回调可能在 `stop` 返回后才结束。
/// - 重复调用 `start` 会先停止旧的事件源、替换回调，不泄漏资源。
public final class SystemNetworkChangeObserver: NetworkChangeObserving, @unchecked Sendable {
    /// 事件来源开关。
    public struct Sources: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let dynamicStore = Sources(rawValue: 1 << 0)
        public static let pathMonitor = Sources(rawValue: 1 << 1)
        public static let workspace = Sources(rawValue: 1 << 2)
        public static let all: Sources = [.dynamicStore, .pathMonitor, .workspace]
    }

    /// 监听的 SCDynamicStore 键。
    public static let watchedKeys = [
        DynamicStoreKeys.globalIPv4,
        DynamicStoreKeys.globalDNS,
    ]

    /// 监听的 SCDynamicStore 键模式（正则）。
    public static let watchedPatterns = [
        "Setup:/Network/Service/.*/DNS",
        "State:/Network/Service/.*/DNS",
        "State:/Network/Interface/utun.*/IPv4",
    ]

    private let enabledSources: Sources
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "io.github.eastcn.tuncanary.system.change-observer")
    private let callbackQueue = DispatchQueue(label: "io.github.eastcn.tuncanary.system.change-observer.callback")

    // 以下状态只在 `queue` 上访问（deinit 除外）。
    private var debouncer: ChangeDebouncer
    private var generation: UInt64 = 0
    private var running = false
    private var installedSources: Sources = []
    private var store: SCDynamicStore?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?

    // 回调与当前代次，由 `deliveryLock` 保护，供回调队列读取。
    private let deliveryLock = NSLock()
    private var activeGeneration: UInt64?
    private var handler: (@Sendable (NetworkChangeEvent) -> Void)?

    /// - Parameters:
    ///   - debounce: 去抖间隔（秒），默认 2 秒。
    ///   - maxDelay: 持续抖动时的最长延迟（秒）。
    ///   - sources: 启用的事件来源，测试时可以关闭系统来源、只用 `noteRawChange` 注入。
    ///   - now: 时钟，决定事件时间。
    public init(
        debounce: TimeInterval = PulseConstants.eventDebounce,
        maxDelay: TimeInterval = ChangeDebouncer.defaultMaxDelay,
        sources: Sources = .all,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.debouncer = ChangeDebouncer(quietInterval: debounce, maxDelay: maxDelay)
        self.enabledSources = sources
        self.now = now
    }

    deinit {
        // 此时已没有其他强引用，事件源的回调都只持有弱引用，直接拆除即可。
        teardownSources()
    }

    /// 是否正在监听。
    public var isRunning: Bool {
        queue.sync { running }
    }

    /// 实际安装成功的事件来源（未运行时为空）。
    public var activeSources: Sources {
        queue.sync { installedSources }
    }

    public func start(handler: @escaping @Sendable (NetworkChangeEvent) -> Void) {
        queue.sync {
            stopLocked()
            generation &+= 1
            let current = generation
            running = true
            deliveryLock.synchronized {
                activeGeneration = current
                self.handler = handler
            }
            installTimer(generation: current)
            installSources(generation: current)
        }
    }

    public func stop() {
        queue.sync { stopLocked() }
    }

    /// 注入一次原始变化（测试或手动触发），与系统事件走同一套去抖逻辑。未运行时忽略。
    public func noteRawChange(_ reason: NetworkChangeReason) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.ingest(reason, generation: self.generation)
        }
    }

    // MARK: - 启停（在 queue 上）

    private func stopLocked() {
        deliveryLock.synchronized {
            activeGeneration = nil
            handler = nil
        }
        guard running else { return }
        running = false
        generation &+= 1
        teardownSources()
        debouncer.reset()
    }

    private func installTimer(generation current: UInt64) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler { [weak self] in
            self?.timerFired(generation: current)
        }
        source.schedule(deadline: .distantFuture)
        source.resume()
        timer = source
    }

    private func installSources(generation current: UInt64) {
        var installed: Sources = []
        if enabledSources.contains(.dynamicStore), installDynamicStore(generation: current) {
            installed.insert(.dynamicStore)
        }
        if enabledSources.contains(.pathMonitor) {
            installPathMonitor(generation: current)
            installed.insert(.pathMonitor)
        }
        if enabledSources.contains(.workspace) {
            installWorkspace(generation: current)
            installed.insert(.workspace)
        }
        installedSources = installed
    }

    /// 拆除全部事件源。在 queue 上或 deinit 中调用。
    private func teardownSources() {
        if let store {
            SCDynamicStoreSetDispatchQueue(store, nil)
            self.store = nil
        }
        pathMonitor?.pathUpdateHandler = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSignature = nil
        if !workspaceTokens.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for token in workspaceTokens { center.removeObserver(token) }
            workspaceTokens = []
        }
        timer?.setEventHandler(handler: nil)
        timer?.cancel()
        timer = nil
        installedSources = []
    }

    // MARK: - 事件源

    /// SCDynamicStore 回调的上下文，只弱引用观察者。
    private final class StoreCallbackBox {
        weak var observer: SystemNetworkChangeObserver?
        let generation: UInt64

        init(observer: SystemNetworkChangeObserver, generation: UInt64) {
            self.observer = observer
            self.generation = generation
        }
    }

    private func installDynamicStore(generation current: UInt64) -> Bool {
        let box = StoreCallbackBox(observer: self, generation: current)
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                _ = Unmanaged<StoreCallbackBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                Unmanaged<StoreCallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let box = Unmanaged<StoreCallbackBox>.fromOpaque(info).takeUnretainedValue()
            // 回调已在 queue 上执行（见 SCDynamicStoreSetDispatchQueue）。
            box.observer?.ingest(.network, generation: box.generation)
        }
        guard let created = SCDynamicStoreCreate(nil, "TunCanary.observer" as CFString, callback, &context) else {
            SystemLog.logger.error("SCDynamicStoreCreate 失败：\(String(cString: SCErrorString(SCError())), privacy: .public)")
            return false
        }
        guard SCDynamicStoreSetNotificationKeys(created, Self.watchedKeys as CFArray, Self.watchedPatterns as CFArray),
              SCDynamicStoreSetDispatchQueue(created, queue) else {
            SystemLog.logger.error("SCDynamicStore 通知设置失败：\(String(cString: SCErrorString(SCError())), privacy: .public)")
            return false
        }
        store = created
        return true
    }

    private func installPathMonitor(generation current: UInt64) {
        let monitor = NWPathMonitor()
        lastPathSignature = nil
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathChanged(Self.signature(of: path), generation: current)
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func installWorkspace(generation current: UInt64) {
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, NetworkChangeReason)] = [
            (NSWorkspace.willSleepNotification, .sleep),
            (NSWorkspace.didWakeNotification, .wake),
        ]
        workspaceTokens = pairs.map { name, reason in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.ingest(reason, generation: current) }
            }
        }
    }

    /// 路径签名：状态、可用接口及其类型、协议支持情况。签名不变的回调不算变化。
    static func signature(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
        return "\(path.status)|\(interfaces)|v4=\(path.supportsIPv4)|v6=\(path.supportsIPv6)|dns=\(path.supportsDNS)"
    }

    private func pathChanged(_ signature: String, generation current: UInt64) {
        guard current == generation, running else { return }
        guard let previous = lastPathSignature else {
            // 首次回调是启动时的初始状态。
            lastPathSignature = signature
            return
        }
        guard previous != signature else { return }
        lastPathSignature = signature
        ingest(.network, generation: current)
    }

    // MARK: - 去抖与投递（在 queue 上）

    private func ingest(_ reason: NetworkChangeReason, generation current: UInt64) {
        guard current == generation, running else { return }
        if let immediate = debouncer.record(reason, at: now()) {
            deliver(immediate, generation: current)
        }
        rescheduleTimer()
    }

    private func timerFired(generation current: UInt64) {
        guard current == generation, running else { return }
        if let event = debouncer.fire(at: now()) {
            deliver(event, generation: current)
        }
        rescheduleTimer()
    }

    private func rescheduleTimer() {
        guard let timer else { return }
        guard let deadline = debouncer.deadline else {
            timer.schedule(deadline: .distantFuture)
            return
        }
        let delay = max(0, deadline.timeIntervalSince(now()))
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(20))
    }

    private func deliver(_ event: NetworkChangeEvent, generation current: UInt64) {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            let handler = self.deliveryLock.synchronized {
                self.activeGeneration == current ? self.handler : nil
            }
            handler?(event)
        }
    }
}
