import Darwin
import Foundation
import TunCanaryCore

private enum EgressResponse: Sendable {
    case body(Data)
    case failure(EgressIPFailure)
}

/// 单个 trace 请求的生命周期。URLSession 回调、取消和看门狗只允许完成一次。
private final class EgressRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumBodyBytes = 16 * 1024

    private let lock = NSLock()
    private var continuation: CheckedContinuation<EgressResponse, Never>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var watchdog: Task<Void, Never>?
    private var body = Data()
    private var finished = false
    private var cancelled = false

    func run(url: URL, configuration: URLSessionConfiguration, timeout: TimeInterval) async -> EgressResponse {
        // configurationFactory 每次须返回新配置；保留测试注入的 protocolClasses。
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<EgressResponse, Never>) in
                lock.lock()
                self.continuation = continuation
                if cancelled {
                    lock.unlock()
                    finish(.failure(.cancelled))
                    return
                }
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                         timeoutInterval: timeout)
                request.httpMethod = "GET"
                request.httpShouldHandleCookies = false
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()

                task.resume()
                let watchdog = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(.timeout))
                }
                lock.lock()
                if finished {
                    lock.unlock()
                    watchdog.cancel()
                } else {
                    self.watchdog = watchdog
                    lock.unlock()
                }
            }
        }, onCancel: {
            lock.lock()
            cancelled = true
            let ready = continuation != nil
            lock.unlock()
            if ready { finish(.failure(.cancelled)) }
        })
    }

    private func finish(_ result: EgressResponse) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let session = self.session
        let task = self.task
        let watchdog = self.watchdog
        self.continuation = nil
        self.session = nil
        self.task = nil
        self.watchdog = nil
        lock.unlock()

        watchdog?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(returning: result)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(.redirect))
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(.invalidResponse))
            return
        }
        if (300...399).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(.failure(.redirect))
            return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            finish(.failure(.httpStatus(http.statusCode)))
            return
        }
        if response.expectedContentLength > Int64(Self.maximumBodyBytes) {
            completionHandler(.cancel)
            finish(.failure(.bodyTooLarge))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let tooLarge = data.count > Self.maximumBodyBytes - body.count
        if !tooLarge { body.append(data) }
        lock.unlock()
        if tooLarge { finish(.failure(.bodyTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            guard let urlError = error as? URLError else {
                finish(.failure(.connectionFailure))
                return
            }
            switch urlError.code {
            case .timedOut: finish(.failure(.timeout))
            case .cancelled: finish(.failure(.cancelled))
            case .cannotFindHost, .dnsLookupFailed: finish(.failure(.dnsFailure))
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot: finish(.failure(.tlsFailure))
            default: finish(.failure(.connectionFailure))
            }
            return
        }
        lock.lock()
        let data = body
        lock.unlock()
        finish(.body(data))
    }
}

/// 按需并发请求各目标（Cloudflare trace 或淘宝 IP 库），由目标回显本应用请求的出口 IP。
public struct EgressIPChecker: EgressIPChecking, Sendable {
    public typealias ConfigurationFactory = @Sendable () -> URLSessionConfiguration

    private let configurationFactory: ConfigurationFactory
    private let timeout: TimeInterval

    /// configurationFactory 供离线 URLProtocol 桩注入；每次调用须返回新的 ephemeral 配置。
    public init(configurationFactory: @escaping ConfigurationFactory = { .ephemeral }, timeout: TimeInterval = 8) {
        self.configurationFactory = configurationFactory
        self.timeout = timeout.isFinite ? min(max(timeout, 0.01), 8) : 8
    }

    public func check(targets: [EgressIPTarget]) async -> [EgressIPResult] {
        await withTaskGroup(of: (Int, EgressIPResult).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask { (index, await inspect(target)) }
            }
            var results: [(Int, EgressIPResult)] = []
            for await item in group { results.append(item) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func inspect(_ target: EgressIPTarget) async -> EgressIPResult {
        let response = await EgressRequest().run(
            url: target.url, configuration: configurationFactory(), timeout: timeout
        )
        let checkedAt = Date()
        switch response {
        case .failure(let failure):
            return EgressIPResult(target: target, checkedAt: checkedAt, ip: nil, ipVersion: nil,
                                  location: nil, failure: failure)
        case .body(let body):
            let parsed = target.format == .taobaoIPInfo ? Self.parseTaobao(body) : Self.parse(body)
            switch parsed {
            case .success(let ip, let version, let location):
                return EgressIPResult(target: target, checkedAt: checkedAt, ip: ip, ipVersion: version,
                                      location: location, failure: nil)
            case .failure(let failure):
                return EgressIPResult(target: target, checkedAt: checkedAt, ip: nil, ipVersion: nil,
                                      location: nil, failure: failure)
            }
        }
    }

    private enum ParsedTrace {
        case success(String, EgressIPVersion, String?)
        case failure(EgressIPFailure)
    }

    private static func parse(_ body: Data) -> ParsedTrace {
        guard let text = String(data: body, encoding: .utf8) else { return .failure(.invalidResponse) }
        var ip: String?
        var location: String?
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return .failure(.invalidResponse) }
            switch parts[0] {
            case "ip":
                guard ip == nil else { return .failure(.invalidResponse) }
                ip = String(parts[1])
            case "loc":
                guard location == nil else { return .failure(.invalidResponse) }
                let value = String(parts[1])
                if value.count == 2 && value.utf8.allSatisfy({ (65...90).contains($0) }) {
                    location = value
                }
            default: break
            }
        }
        guard let ip else { return .failure(.missingIP) }
        return classify(ip, location: location)
    }

    /// 淘宝 IP 库：`{"code":0,"data":{"ip":…,"country_id":"CN","region":…,"city":…}}`。
    /// 非 0 的 code（例如限流）判为接口拒绝；归属地取国家代码加省市，去掉控制字符并限长。
    private static func parseTaobao(_ body: Data) -> ParsedTrace {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let code = object["code"] as? Int else { return .failure(.invalidResponse) }
        guard code == 0 else { return .failure(.serviceRejected) }
        guard let data = object["data"] as? [String: Any] else { return .failure(.invalidResponse) }
        guard let ip = data["ip"] as? String, !ip.isEmpty else { return .failure(.missingIP) }
        var parts: [String] = []
        if let country = data["country_id"] as? String,
           country.count == 2, country.utf8.allSatisfy({ (65...90).contains($0) }) {
            parts.append(country)
        }
        let place = ["region", "city"].compactMap { key -> String? in
            guard let value = data[key] as? String else { return nil }
            let cleaned = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
                .trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty || cleaned == "XX" ? nil : String(cleaned.prefix(20))
        }
        var unique: [String] = []
        for item in place where !unique.contains(item) { unique.append(item) }
        if !unique.isEmpty { parts.append(unique.joined(separator: " ")) }
        return classify(ip, location: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    private static func classify(_ ip: String, location: String?) -> ParsedTrace {
        // inet_pton 接收 C 字符串；嵌入 NUL 会让后缀被忽略，必须先拒绝。
        guard !ip.utf8.contains(0) else { return .failure(.invalidIP) }
        var ipv4 = in_addr()
        if ip.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return .success(ip, .ipv4, location)
        }
        var ipv6 = in6_addr()
        if ip.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return .success(ip, .ipv6, location)
        }
        return .failure(.invalidIP)
    }
}
