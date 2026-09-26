import Foundation

/// `Probe.*` 测试专用的 URLProtocol 桩：不访问网络，按 URL 精确匹配返回预先注册的响应。
/// 通过 `URLSessionConfiguration.protocolClasses` 注入，不做全局 `URLProtocol.registerClass`。
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// 一次请求应如何响应。
    struct Response: Sendable {
        var status: Int?
        var headers: [String: String] = [:]
        /// 延迟多久再响应（秒），用于制造并发窗口或测量延迟。
        var delay: TimeInterval = 0
        /// 直接以该错误码失败（模拟 DNS/连接/TLS 错误，或系统上报的超时）。
        var error: URLError.Code?
        /// 永不响应，直到被取消——用于测试看门狗/超时。
        var hang = false

        static func http(_ status: Int, headers: [String: String] = [:], delay: TimeInterval = 0) -> Response {
            Response(status: status, headers: headers, delay: delay)
        }

        static func failure(_ code: URLError.Code, delay: TimeInterval = 0) -> Response {
            Response(delay: delay, error: code)
        }

        static var hangForever: Response { Response(hang: true) }
    }

    private static let lock = NSLock()
    private static var handlers: [String: @Sendable (URLRequest) -> Response] = [:]
    private static var requestLog: [(url: String, cookieHeader: String?)] = []
    private static var activeCount = 0
    private static var peakActiveCount = 0

    /// 清空全部状态；每个用例开始前调用。
    static func reset() {
        lock.lock()
        handlers = [:]
        requestLog = []
        activeCount = 0
        peakActiveCount = 0
        lock.unlock()
    }

    /// 为某个 URL 注册响应处理器（按完整 URL 字符串精确匹配）。
    static func register(_ url: URL, _ handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.lock()
        handlers[url.absoluteString] = handler
        lock.unlock()
    }

    /// 为某个 URL 注册固定响应。
    static func register(_ url: URL, _ response: Response) {
        register(url) { _ in response }
    }

    /// 已发起的请求 URL（按发起顺序），用于验证“未跟随重定向”“未请求某目标”。
    static var requestedURLs: [String] {
        lock.lock(); defer { lock.unlock() }
        return requestLog.map(\.url)
    }

    /// 每次请求携带的 Cookie 请求头（nil 表示没有该请求头），用于验证不带 Cookie。
    static var cookieHeaders: [String?] {
        lock.lock(); defer { lock.unlock() }
        return requestLog.map(\.cookieHeader)
    }

    /// 观测到的最大同时在途请求数，用于验证并发上限。
    static var maxConcurrentRequests: Int {
        lock.lock(); defer { lock.unlock() }
        return peakActiveCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        StubURLProtocol.lock.lock()
        StubURLProtocol.requestLog.append((url.absoluteString, request.value(forHTTPHeaderField: "Cookie")))
        StubURLProtocol.activeCount += 1
        StubURLProtocol.peakActiveCount = max(StubURLProtocol.peakActiveCount, StubURLProtocol.activeCount)
        let handler = StubURLProtocol.handlers[url.absoluteString]
        StubURLProtocol.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = handler(request)

        if response.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { [weak self] in
                self?.deliver(response, for: url)
            }
        } else {
            deliver(response, for: url)
        }
    }

    private func deliver(_ response: Response, for url: URL) {
        if response.hang { return } // 永不回调，等待外部取消
        if let code = response.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        guard let status = response.status,
              let httpResponse = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: response.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        StubURLProtocol.lock.lock()
        StubURLProtocol.activeCount -= 1
        StubURLProtocol.lock.unlock()
    }

    /// 构造一个使用本桩的 `.ephemeral` 配置。
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }
}
