import Foundation
import TunCanaryCore

/// 只在一次探测请求的生命周期内使用一次的“只能触发一次”门闩，避免看门狗与正常完成竞争导致
/// continuation 被 resume 两次。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// 首次调用返回 true，之后都返回 false。
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// 单次 GET 请求的协调者：新建 ephemeral 会话、不跟随重定向、收到响应头即取消读取正文，
/// 用 `URLSessionTaskMetrics` 计算延迟（拿不到时退回墙钟计时），并用看门狗保证不超过超时。
///
/// 说明：`URLSessionTaskMetrics` 的 `didFinishCollecting` 回调在 `didCompleteWithError` 之前触发，
/// 所以真正决定结果、resume continuation 的地方是 `didCompleteWithError`；`didFinishCollecting`
/// 只负责记录延迟。看门狗与正常完成路径都通过 `ResumeOnce` 保证只 resume 一次。
private final class SingleRequestCoordinator: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = ResumeOnce()
    private var continuation: CheckedContinuation<RequestOutcome, Never>?
    private var task: URLSessionTask?
    private var cancelled = false

    private let requestStart = Date()
    private var httpStatus: Int?
    private var responseReceivedAt: Date?
    private var metricsLatency: TimeInterval?

    /// 发起一次请求。`configuration` 由调用方每次新建（ephemeral，测试可注入 protocolClasses）。
    func run(url: URL, configuration: URLSessionConfiguration, timeout: TimeInterval) async -> RequestOutcome {
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        return await withTaskCancellationHandler(operation: {
          await withCheckedContinuation { (continuation: CheckedContinuation<RequestOutcome, Never>) in
            lock.lock()
            self.continuation = continuation
            if cancelled {
                lock.unlock()
                cancel()
                return
            }

            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
            request.httpMethod = "GET"
            let dataTask = session.dataTask(with: request)
            self.task = dataTask
            lock.unlock()
            dataTask.resume()
            // 请求结束后使会话失效，避免泄漏；不影响已发出的任务。
            session.finishTasksAndInvalidate()

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                self?.watchdogFire()
            }
          }
        }, onCancel: { self.cancel() })
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        let ready = continuation != nil
        lock.unlock()
        task?.cancel()
        if ready, gate.claim() { resume(.failure(.connectionFailure, detail: "检查已取消")) }
    }

    /// 看门狗：保证总时长不超过 timeout。真正的网络错误码可能因平台差异而来得晚，这里直接判为超时。
    private func watchdogFire() {
        guard gate.claim() else { return }
        task?.cancel()
        resume(.failure(.timeout, detail: "看门狗：超过单次超时"))
    }

    // MARK: URLSessionTaskDelegate / URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // 不跟随重定向；同时记录状态码，兼容“拒绝重定向后是否还会收到 didReceive”的平台差异。
        lock.lock()
        httpStatus = response.statusCode
        responseReceivedAt = Date()
        lock.unlock()
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        if let http = response as? HTTPURLResponse {
            httpStatus = http.statusCode
        }
        responseReceivedAt = Date()
        lock.unlock()
        // 收到响应头后立即取消，不读取正文。
        completionHandler(.cancel)
    }

    /// 只负责记录延迟。实测顺序上 `didFinishCollecting` 先于 `didCompleteWithError` 触发，
    /// 真正的结果判定和 resume 放在 `didCompleteWithError` 里。
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last(where: { $0.responseStartDate != nil }),
              let fetchStart = transaction.fetchStartDate,
              let responseStart = transaction.responseStartDate else { return }
        lock.lock()
        metricsLatency = responseStart.timeIntervalSince(fetchStart)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard gate.claim() else { return }

        lock.lock()
        let status = httpStatus
        let responseAt = responseReceivedAt
        // 测试桩等场景拿不到 metrics 的真实时间戳时，退回到墙钟计时。
        let latency = metricsLatency ?? responseAt.map { $0.timeIntervalSince(requestStart) }
        lock.unlock()

        // 已收到响应头：无论完成回调里带着什么错误（通常是我们主动取消产生的 .cancelled），
        // 都按已收到的状态码判定，区分“主动取消”和“真正的错误”。
        if let status {
            resume(.http(status: status, latency: latency))
            return
        }
        if let urlError = error as? URLError {
            resume(.failure(ProbeCategory(urlErrorCode: urlError.code), detail: urlError.localizedDescription))
            return
        }
        if let error {
            resume(.failure(.connectionFailure, detail: error.localizedDescription))
            return
        }
        resume(.failure(.connectionFailure, detail: "未知错误：既无响应也无错误"))
    }

    private func resume(_ outcome: RequestOutcome) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}

/// 基于 `URLSession` 的站点探测器。每次请求新建一个 ephemeral 会话，不带 Cookie、不用缓存，
/// GET 不跟随重定向，收到响应头即取消读取正文；延迟优先取 `URLSessionTaskMetrics`，拿不到时退回墙钟计时。
///
/// 并发语义：`probe(site:attempts:timeout:)` 内部串行发起 `attempts` 次请求（逐次 await），
/// 不在内部并发；多站点并发由 `ProbeBatch` 负责。类型本身是 `Sendable`，可以安全地在多个并发
/// 调用方之间共享同一个实例（例如 `ProbeBatch` 并发调用同一个 prober 探测不同站点）。
public struct URLSessionSiteProber: SiteProbing, Sendable {
    /// 构造每次请求使用的基础配置。默认返回新的 `.ephemeral` 配置；测试可注入
    /// 带自定义 `protocolClasses` 的配置来使用 URLProtocol 桩。每次调用都应返回新实例，
    /// 因为调用方会就地修改其超时、Cookie 与缓存相关字段。
    public typealias ConfigurationFactory = @Sendable () -> URLSessionConfiguration

    private let configurationFactory: ConfigurationFactory

    public init(configurationFactory: @escaping ConfigurationFactory = { .ephemeral }) {
        self.configurationFactory = configurationFactory
    }

    /// 串行发起 `attempts` 次 GET，用 `SiteAggregator.aggregate` 汇总。不抛错。
    public func probe(site: Site, attempts: Int, timeout: TimeInterval) async -> SiteResult {
        var outcomes: [RequestOutcome] = []
        let count = max(attempts, 0)
        outcomes.reserveCapacity(count)
        for _ in 0..<count {
            guard !Task.isCancelled else { break }
            let configuration = configurationFactory()
            let coordinator = SingleRequestCoordinator()
            outcomes.append(await coordinator.run(url: site.url, configuration: configuration, timeout: timeout))
        }
        return SiteAggregator.aggregate(site: site, outcomes: outcomes, checkedAt: Date())
    }
}
