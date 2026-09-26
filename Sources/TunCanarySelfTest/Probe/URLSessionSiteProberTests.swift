import Foundation
import TunCanaryCore
import TunCanaryProbe

/// 线程安全的调用计数器，供“按调用次数返回不同响应”的桩闭包使用。
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// 返回当前计数（从 0 开始），并自增。
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

/// `URLSessionSiteProber` 的桩测试：覆盖计划要求的全部 8 类结果，以及重定向、Cookie 隔离、
/// 延迟中位数。全部用例都用 `StubURLProtocol`，不访问网络。
enum URLSessionSiteProberTests {
    static func makeSite(_ url: URL, key: Bool = true) -> Site {
        Site(id: "test", name: "测试站点", group: .overseas, url: url, isKey: key, inLightProbe: key)
    }

    static func makeProber() -> URLSessionSiteProber {
        URLSessionSiteProber(configurationFactory: { StubURLProtocol.makeConfiguration() })
    }

    static var suite: TestSuite {
        TestSuite("Probe.URLSessionSiteProber", [
            TestCase("取消在途请求立即结束且不再发起后续请求", timeout: 5) { t in
                StubURLProtocol.reset()
                let url = URL(string: "https://stub.test/cancel")!
                StubURLProtocol.register(url, .hangForever)
                let task = Task { await makeProber().probe(site: makeSite(url), attempts: 3, timeout: 4) }
                for _ in 0..<100 {
                    if !StubURLProtocol.requestedURLs.isEmpty { break }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                t.expectEqual(StubURLProtocol.requestedURLs.count, 1)
                let start = Date()
                task.cancel()
                let result = await task.value
                t.expect(Date().timeIntervalSince(start) < 1, "取消不应等待单次超时")
                t.expectEqual(result.attempts.count, 1)
                t.expectEqual(StubURLProtocol.requestedURLs.count, 1)
            },
            TestCase("200 可达") { t in
                StubURLProtocol.reset()
                let url = URL(string: "https://stub.test/200")!
                StubURLProtocol.register(url, .http(200))
                let result = await makeProber().probe(site: makeSite(url), attempts: 1, timeout: 2)
                t.expectEqual(result.category, .reachable)
                t.expect(!result.isFailure)
            },
            TestCase("204 可达") { t in
                StubURLProtocol.reset()
                let url = URL(string: "https://stub.test/204")!
                StubURLProtocol.register(url, .http(204))
                let result = await makeProber().probe(site: makeSite(url), attempts: 1, timeout: 2)
                t.expectEqual(result.category, .reachable)
            },
            TestCase("301 可达，且不请求重定向目标") { t in
                StubURLProtocol.reset()
                let url = URL(string: "https://stub.test/301")!
                let target = URL(string: "https://stub.test/should-never-be-requested")!
                StubURLProtocol.register(url, .http(301, headers: ["Location": target.absoluteString]))
                let result = await makeProber().probe(site: makeSite(url), attempts: 1, timeout: 2)
                t.expectEqual(result.category, .reachable)
                t.expect(!StubURLProtocol.requestedURLs.contains(target.absoluteString), "不应请求重定向目标")
            },
            TestCase("403 访问受限") { t in
                StubURLProtocol.reset()
                let url = URL(string: "https://stub.test/403")!
                StubURLProtocol.register(url, .http(403))
                let result = await makeProber().probe(site: makeSite(url), attempts: 1, timeout: 2)
                t.expectEqual(result.category, .restricted)
                t.expect(!result.isFailure, "4xx 不计为失败")
            },
            TestCase("500 服务端错误") { t in
                StubURLProtocol.reset()
                let url = URL(string: "https://stub.test/500")!
                StubURLProtocol.register(url, .http(500))
                let result = await makeProber().probe(site: makeSite(url), attempts: 1, timeout: 2)
                t.expectEqual(result.category, .serverError)
                t.expect(result.isFailure)
            },
            TestCase("TLS 错误") { t in
                StubURLProtocol.reset()
                let url = URL(string: "https://stub.test/tls")!
                StubURLProtocol.register(url, .failure(.secureConnectionFailed))
                let result = await makeProber().probe(site: makeSite(url), attempts: 1, timeout: 2)
                t.expectEqual(result.category, .tlsError)
                t.expect(result.isFailure)
            },
            TestCase("超时：桩延迟超过超时时间", timeout: 5) { t in
                StubURLProtocol.reset()
                let url = URL(string: "https://stub.test/slow")!
                StubURLProtocol.register(url, .http(200, delay: 2))
                let start = Date()
                let result = await makeProber().probe(site: makeSite(url), attempts: 1, timeout: 0.3)
                let elapsed = Date().timeIntervalSince(start)
                t.expectEqual(result.category, .timeout)
                t.expect(elapsed < 1.5, "看门狗应保证总时长不明显超过超时（实际 \(elapsed) 秒）")
            },
            TestCase("超时：桩直接返回 .timedOut") { t in
                StubURLProtocol.reset()
                let url = URL(string: "https://stub.test/timedout")!
                StubURLProtocol.register(url, .failure(.timedOut))
                let result = await makeProber().probe(site: makeSite(url), attempts: 1, timeout: 2)
                t.expectEqual(result.category, .timeout)
            },
            TestCase("DNS 失败") { t in
                StubURLProtocol.reset()
                let url = URL(string: "https://stub.test/dns")!
                StubURLProtocol.register(url, .failure(.cannotFindHost))
                let result = await makeProber().probe(site: makeSite(url), attempts: 1, timeout: 2)
                t.expectEqual(result.category, .dnsFailure)

                StubURLProtocol.reset()
                let url2 = URL(string: "https://stub.test/dns2")!
                StubURLProtocol.register(url2, .failure(.dnsLookupFailed))
                let result2 = await makeProber().probe(site: makeSite(url2), attempts: 1, timeout: 2)
                t.expectEqual(result2.category, .dnsFailure)
            },
            TestCase("连接失败") { t in
                StubURLProtocol.reset()
                let url = URL(string: "https://stub.test/refused")!
                StubURLProtocol.register(url, .failure(.cannotConnectToHost))
                let result = await makeProber().probe(site: makeSite(url), attempts: 1, timeout: 2)
                t.expectEqual(result.category, .connectionFailure)

                StubURLProtocol.reset()
                let url2 = URL(string: "https://stub.test/reset")!
                StubURLProtocol.register(url2, .failure(.networkConnectionLost))
                let result2 = await makeProber().probe(site: makeSite(url2), attempts: 1, timeout: 2)
                t.expectEqual(result2.category, .connectionFailure)
            },

            // MARK: 汇总与延迟

            TestCase("3 次请求的汇总与延迟中位数") { t in
                StubURLProtocol.reset()
                let url = URL(string: "https://stub.test/median")!
                let counter = CallCounter()
                let delays: [TimeInterval] = [0.02, 0.06, 0.04]
                StubURLProtocol.register(url) { _ in
                    let call = counter.next()
                    let delay = delays[min(call, delays.count - 1)]
                    return .http(200, delay: delay)
                }
                let result = await makeProber().probe(site: makeSite(url), attempts: 3, timeout: 2)
                t.expectEqual(result.category, .reachable)
                t.expectEqual(result.attempts.count, 3)
                let median = try t.require(result.medianLatency)
                // 中位数应为 0.04 附近（三次延迟排序后取中间值），容忍调度误差。
                t.expect(median > 0.02 && median < 0.09, "延迟中位数异常：\(median)")
            },
            TestCase("2 可达 1 失败 → 汇总可达（3 次至少 2 次门槛）") { t in
                StubURLProtocol.reset()
                let url = URL(string: "https://stub.test/majority")!
                let counter = CallCounter()
                StubURLProtocol.register(url) { _ in
                    counter.next() == 1 ? .failure(.timedOut) : .http(200, delay: 0.01)
                }
                let result = await makeProber().probe(site: makeSite(url), attempts: 3, timeout: 2)
                t.expectEqual(result.category, .reachable)
                t.expect(!result.isFailure)
            },

            // MARK: 会话隔离

            TestCase("每次请求使用独立会话、不带 Cookie") { t in
                StubURLProtocol.reset()
                let url = URL(string: "https://stub.test/cookie")!
                StubURLProtocol.register(url, .http(200, headers: ["Set-Cookie": "session=abc; Path=/"]))
                _ = await makeProber().probe(site: makeSite(url), attempts: 3, timeout: 2)
                let cookies = StubURLProtocol.cookieHeaders
                t.expectEqual(cookies.count, 3)
                t.expect(cookies.allSatisfy { $0 == nil }, "不应有任何一次请求带上 Cookie")
            },
        ])
    }
}
