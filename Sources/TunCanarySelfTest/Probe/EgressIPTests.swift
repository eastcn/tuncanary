import Foundation
import TunCanaryCore
import TunCanaryProbe

/// 独立正文桩；所有用例只在内存中回放，不连接 trace 站点。
private final class TraceURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var data = Data()
        var headers: [String: String] = [:]
        var error: URLError.Code?
        var hang = false

        static func text(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, data: Data(text.utf8), headers: headers)
        }
    }

    private static let lock = NSLock()
    private static var replies: [String: Reply] = [:]
    private static var seen: [(url: String, cookie: String?)] = []

    static func reset(_ claude: Reply, _ cloudflare: Reply) {
        lock.lock()
        replies = [EgressIPTarget.claude.url.absoluteString: claude,
                   EgressIPTarget.cloudflare.url.absoluteString: cloudflare]
        seen = []
        lock.unlock()
    }

    static func add(_ target: EgressIPTarget, _ reply: Reply) {
        lock.lock()
        replies[target.url.absoluteString] = reply
        lock.unlock()
    }

    static var requests: [(url: String, cookie: String?)] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TraceURLProtocol.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.seen.append((url.absoluteString, request.value(forHTTPHeaderField: "Cookie")))
        let reply = Self.replies[url.absoluteString]
        Self.lock.unlock()
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        if reply.hang { return }
        if let code = reply.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                             httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.data.isEmpty { client?.urlProtocol(self, didLoad: reply.data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum EgressIPTests {
    /// 两个 trace 目标，各自有独立的回放正文。
    private static let pair: [EgressIPTarget] = [.claude, .cloudflare]

    private static func checker(timeout: TimeInterval = 1) -> EgressIPChecker {
        EgressIPChecker(configurationFactory: { TraceURLProtocol.configuration() }, timeout: timeout)
    }

    static var suite: TestSuite {
        TestSuite("Probe.EgressIP", [
            TestCase("200 分别解析目标所见 IPv4 和 IPv6") { t in
                TraceURLProtocol.reset(.text("ip=203.0.113.17\nloc=US\n"),
                                       .text("ip=2001:db8::17\nloc=JP\n"))
                let results = await checker().check(targets: pair)
                t.expectEqual(results.count, 2)
                t.expectEqual(results.map(\.target), [.claude, .cloudflare])
                t.expectEqual(results[0].ip, "203.0.113.17")
                t.expectEqual(results[0].ipVersion, .ipv4)
                t.expectEqual(results[0].location, "US")
                t.expectEqual(results[1].ip, "2001:db8::17")
                t.expectEqual(results[1].ipVersion, .ipv6)
                t.expectEqual(results[1].location, "JP")
                t.expect(results.allSatisfy { $0.isSuccess })
                t.expect(results.allSatisfy { $0.checkedAt <= Date() })
                t.expectEqual(TraceURLProtocol.requests.count, 2)
                t.expect(TraceURLProtocol.requests.allSatisfy { $0.cookie == nil })
            },
            TestCase("只检测给定目标，结果按传入顺序") { t in
                TraceURLProtocol.reset(.text("ip=203.0.113.17\nloc=US\n"),
                                       .text("ip=2001:db8::17\nloc=JP\n"))
                let only = await checker().check(targets: [.cloudflare])
                t.expectEqual(only.map(\.target), [.cloudflare])
                t.expectEqual(only.first?.ip, "2001:db8::17")
                let reversed = await checker().check(targets: [.cloudflare, .claude])
                t.expectEqual(reversed.map(\.target), [.cloudflare, .claude])
            },
            TestCase("自定义目标访问该域名的 trace，与内置目标一起按顺序返回") { t in
                TraceURLProtocol.reset(.text("ip=203.0.113.17\n"), .text("ip=203.0.113.18\n"))
                let custom = try t.require(EgressIPTarget.custom("trace.example.test"))
                let missing = try t.require(EgressIPTarget.custom("plain.example.test"))
                TraceURLProtocol.add(custom, .text("ip=198.51.100.9\nloc=SG\n"))
                TraceURLProtocol.add(missing, .text("not found", status: 404))
                let results = await checker().check(targets: [.cloudflare, custom, missing])
                t.expectEqual(results.map(\.target), [.cloudflare, custom, missing])
                t.expectEqual(results[1].ip, "198.51.100.9")
                t.expectEqual(results[1].location, "SG")
                t.expectEqual(results[2].failure, .httpStatus(404))
                t.expect(TraceURLProtocol.requests.map(\.url).contains("https://trace.example.test/cdn-cgi/trace"))
            },
            TestCase("淘宝 IP 库：解析 JSON，限流判为接口拒绝") { t in
                TraceURLProtocol.reset(.text("ip=203.0.113.17\n"), .text("ip=203.0.113.18\n"))
                TraceURLProtocol.add(.taobao, .text("""
                    {"code":0,"data":{"ip":"198.51.100.8","country_id":"CN","region":"浙江","city":"杭州","isp":"XX"}}
                    """))
                var results = await checker().check(targets: [.taobao])
                t.expectEqual(results.first?.ip, "198.51.100.8")
                t.expectEqual(results.first?.ipVersion, .ipv4)
                t.expectEqual(results.first?.location, "CN · 浙江 杭州")
                t.expect(TraceURLProtocol.requests.contains { $0.url.hasPrefix("https://ip.taobao.com/outGetIpInfo?") })

                TraceURLProtocol.add(.taobao, .text(#"{"code":0,"data":{"ip":"198.51.100.8","region":"XX","city":"XX"}}"#))
                results = await checker().check(targets: [.taobao])
                t.expectNil(results.first?.location, "XX 表示未知")

                TraceURLProtocol.add(.taobao, .text(#"{"msg":"the request over max qps for user","code":4}"#))
                results = await checker().check(targets: [.taobao])
                t.expectEqual(results.first?.failure, .serviceRejected)
                t.expectNil(results.first?.ip)

                TraceURLProtocol.add(.taobao, .text(#"{"code":0,"data":{"ip":"999.1.1.1"}}"#))
                results = await checker().check(targets: [.taobao])
                t.expectEqual(results.first?.failure, .invalidIP)

                TraceURLProtocol.add(.taobao, .text("ip=198.51.100.8\n"))
                results = await checker().check(targets: [.taobao])
                t.expectEqual(results.first?.failure, .invalidResponse, "不是 JSON")
            },
            TestCase("缺少 ip 与非法 ip 不产生旧值") { t in
                TraceURLProtocol.reset(.text("loc=US\n"), .text("ip=999.1.2.3\n"))
                let results = await checker().check(targets: pair)
                t.expectEqual(results[0].failure, .missingIP)
                t.expectEqual(results[1].failure, .invalidIP)
                t.expect(results.allSatisfy { $0.ip == nil && $0.ipVersion == nil && $0.location == nil })
            },
            TestCase("无效 UTF8 与重复 ip 判为格式错误") { t in
                TraceURLProtocol.reset(TraceURLProtocol.Reply(data: Data([0xFF])),
                                       .text("ip=203.0.113.1\nip=203.0.113.2\n"))
                let results = await checker().check(targets: pair)
                t.expectEqual(results.map(\.failure), [.invalidResponse, .invalidResponse])
            },
            TestCase("嵌入 NUL 不得只验证 IP 前缀") { t in
                TraceURLProtocol.reset(.text("ip=203.0.113.1\0wrong\n"),
                                       .text("ip=2001:db8::1\0wrong\n"))
                let results = await checker().check(targets: pair)
                t.expectEqual(results.map(\.failure), [.invalidIP, .invalidIP])
            },
            TestCase("非 200 和重定向不返回 IP") { t in
                let redirected = TraceURLProtocol.Reply.text("ip=203.0.113.4\n", status: 302,
                                                            headers: ["Location": "https://elsewhere.test/trace"])
                TraceURLProtocol.reset(.text("ip=203.0.113.3\n", status: 503), redirected)
                let results = await checker().check(targets: pair)
                t.expectEqual(results[0].failure, .httpStatus(503))
                t.expectEqual(results[1].failure, .redirect)
                t.expect(results.allSatisfy { $0.ip == nil })
                t.expectEqual(TraceURLProtocol.requests.count, 2)
            },
            TestCase("超过 16 KiB 的正文直接失败") { t in
                let oversized = String(repeating: "x", count: 16 * 1024 + 1)
                TraceURLProtocol.reset(.text("ip=203.0.113.5\n" + oversized),
                                       .text("ip=203.0.113.6\n"))
                let results = await checker().check(targets: pair)
                t.expectEqual(results[0].failure, .bodyTooLarge)
                t.expectEqual(results[1].ip, "203.0.113.6")
            },
            TestCase("超时和 DNS 失败明确分类", timeout: 3) { t in
                TraceURLProtocol.reset(TraceURLProtocol.Reply(hang: true),
                                       TraceURLProtocol.Reply(error: .cannotFindHost))
                let start = Date()
                let results = await checker(timeout: 0.1).check(targets: pair)
                t.expectEqual(results.map(\.failure), [.timeout, .dnsFailure])
                t.expect(Date().timeIntervalSince(start) < 1, "单轮检查应及时结束")
            },
            TestCase("取消同时终止两个在途请求", timeout: 3) { t in
                TraceURLProtocol.reset(TraceURLProtocol.Reply(hang: true),
                                       TraceURLProtocol.Reply(hang: true))
                let task = Task { await checker(timeout: 2).check(targets: pair) }
                for _ in 0..<100 {
                    if TraceURLProtocol.requests.count == 2 { break }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                t.expectEqual(TraceURLProtocol.requests.count, 2)
                let start = Date()
                task.cancel()
                let results = await task.value
                t.expectEqual(results.map(\.failure), [.cancelled, .cancelled])
                t.expect(Date().timeIntervalSince(start) < 1, "取消不应等待看门狗")
            },
            TestCase("非有限超时参数回退默认值") { t in
                TraceURLProtocol.reset(.text("ip=203.0.113.1\n"),
                                       .text("ip=203.0.113.2\n"))
                let results = await checker(timeout: .nan).check(targets: pair)
                t.expect(results.allSatisfy { $0.isSuccess })
            },
        ])
    }
}
