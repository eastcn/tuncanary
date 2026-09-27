import Foundation
import TunCanaryCore

/// 收集日志流中匹配的连接（跨线程）。
private final class ConnectionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var matched: [ProxyLogConnection] = []
    private var stopped = false

    func append(_ connection: ProxyLogConnection) {
        lock.lock()
        matched.append(connection)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    var connections: [ProxyLogConnection] {
        lock.lock()
        defer { lock.unlock() }
        return matched
    }
}

/// 站点失败诊断：订阅 mihomo 日志流的同时复测一次，找到本进程发往该站点的连接，
/// 记录命中的规则和出站链；复测仍失败且经过节点时，再对节点测一次延迟。只读，不改代理配置。
public struct ProxyDiagnoser: SiteDiagnosing {
    private let prober: SiteProbing
    private let processName: String
    private let locate: @Sendable () -> Result<MihomoController, MihomoControllerError>
    private let probeTimeout: TimeInterval
    private let delayTimeout: TimeInterval

    /// - Parameters:
    ///   - prober: 复测使用的站点探测器。
    ///   - processName: 日志中本进程的名称，默认取当前进程名。
    public init(prober: SiteProbing,
                processName: String = ProcessInfo.processInfo.processName,
                probeTimeout: TimeInterval = PulseConstants.probeTimeout,
                delayTimeout: TimeInterval = 5,
                locate: @escaping @Sendable () -> Result<MihomoController, MihomoControllerError> = MihomoController.locate) {
        self.prober = prober
        self.processName = processName
        self.probeTimeout = probeTimeout
        self.delayTimeout = delayTimeout
        self.locate = locate
    }

    public func diagnose(site: Site, tunRunning: Bool, manual: Bool) async -> SiteDiagnosis {
        let started = Date()
        func finish(_ outcome: RequestOutcome, _ route: ProxyRoute, _ delay: NodeDelay? = nil) -> SiteDiagnosis {
            SiteDiagnosis(siteID: site.id, siteName: site.name, diagnosedAt: started, manual: manual,
                          outcome: outcome, route: route, nodeDelay: delay)
        }

        let controller: MihomoController
        switch locate() {
        case .success(let value):
            controller = value
        case .failure(let error):
            return finish(await probeOnce(site), .unavailable(reason: error.message))
        }

        let host = (site.url.host ?? "").lowercased()
        let port = site.url.port ?? (site.url.scheme?.lowercased() == "http" ? 80 : 443)
        let processName = self.processName
        let collector = ConnectionCollector()
        let streamTimeout = probeTimeout + 3
        let streamTask = Task.detached(priority: .utility) { () -> MihomoControllerError? in
            controller.streamConnections(timeout: streamTimeout, shouldStop: { collector.isStopped }) { connection in
                guard connection.process == processName, connection.host.lowercased() == host,
                      connection.port == port else { return }
                collector.append(connection)
            }
        }
        // 等订阅建立后再发请求。
        try? await Task.sleep(nanoseconds: 200_000_000)
        let outcome = await probeOnce(site)
        // 拨号失败的日志可能晚于请求结束到达。
        try? await Task.sleep(nanoseconds: 400_000_000)
        collector.stop()
        let streamError = await streamTask.value

        // 匹配记录带具体节点，拨号失败记录只有策略组名：以匹配记录为准，合并拨号错误。
        let connections = collector.connections
        let failure = connections.last { $0.error != nil }
        guard var connection = connections.last(where: { $0.error == nil }) ?? failure else {
            if let streamError { return finish(outcome, .unavailable(reason: streamError.message)) }
            return finish(outcome, .notInProxy(tunRunning: tunRunning))
        }
        if let failure { connection.error = failure.error }
        let viaTun = connection.source != "127.0.0.1" && connection.source != "::1"
        var delay: NodeDelay?
        if outcome.category.countsAsFailure && !connection.isDirect {
            let node = connection.node
            let timeout = delayTimeout
            delay = await Task.detached(priority: .utility) { controller.delay(node: node, timeout: timeout) }.value
        }
        return finish(outcome, .proxied(connection, viaTun: viaTun), delay)
    }

    private func probeOnce(_ site: Site) async -> RequestOutcome {
        let result = await prober.probe(site: site, attempts: 1, timeout: probeTimeout)
        return result.attempts.first ?? .failure(.connectionFailure, detail: "未发出请求")
    }
}
