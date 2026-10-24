import Foundation
import TunCanaryCore
import TunCanarySystem

enum DNSGuardSplitDNSProberTests {
    static let rule = DNSGuardSplitDNSTests.rule
    static let address = IPv4("10.20.0.8")!
    static let fake = IPv4("198.18.0.80")!

    final class Stub: @unchecked Sendable {
        let lock = NSLock()
        var files: Result<String, DNSGuardSystemSplitDNSProber.ReadError> = .success(
            "nameserver 10.9.0.53\nnameserver 10.9.0.54\n")
        var resolvers: [Resolver]? = [Resolver(isScoped: false, number: 2, domain: rule.domain, nameservers: rule.servers)]
        var resolved: CanaryResult = .resolved([address])
        var upstream: DNSGuardProbeResult = .answered([address])
        var publicAnswers: CanaryResult = .resolved([fake])
        var queries: [String] = []
        var reads = 0
        var changeAfterQuery = false
        func resolve(_ host: String) -> CanaryResult {
            lock.lock(); defer { lock.unlock() }
            queries.append(host)
            return host.hasPrefix("dns-guard-") ? publicAnswers : resolved
        }
        func load() -> [Resolver]? {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            return changeAfterQuery && reads > 1 ? [] : resolvers
        }
        func prober() -> DNSGuardSystemSplitDNSProber {
            DNSGuardSystemSplitDNSProber(readFile: { _ in self.files },
                loadResolvers: { self.load() }, resolve: { self.resolve($0) },
                directResolve: { _, _ in self.upstream })
        }
    }

    static var suite: TestSuite {
        TestSuite("System.DNSGuardSplitDNS", [
            TestCase("持久化、实际规则、系统答案和上游均通过才放行") { t in
                let stub = Stub()
                let result = await stub.prober().probe(host: "probe.corp.example", rules: [rule], publicProbe: nil)
                t.expectEqual(result, .answered([address]))
                t.expectEqual(stub.queries, ["probe.corp.example"])
                t.expectEqual(stub.reads, 2)
            },
            TestCase("无持久化文件、配置未生效及文件地址漂移时，不发起系统查询") { t in
                for kind in 0..<3 {
                    let stub = Stub()
                    if kind == 0 { stub.files = .failure(.init("文件权限不安全")) }
                    if kind == 1 { stub.resolvers = [] }
                    if kind == 2 { stub.files = .success("nameserver 192.0.2.99") }
                    let result = await stub.prober().probe(host: "probe.corp.example", rules: [rule], publicProbe: nil)
                    if case .failed = result {} else { t.fail("规则无效时必须失败") }
                    t.expectEqual(stub.queries, [])
                }
            },
            TestCase("系统失败、旧缓存与上游不一致、上游无响应均拒绝接管") { t in
                for kind in 0..<3 {
                    let stub = Stub()
                    if kind == 0 { stub.resolved = .failed(reason: "合成超时") }
                    if kind == 1 { stub.upstream = .answered([IPv4("10.20.0.99")!]) }
                    if kind == 2 { stub.upstream = .noResponse }
                    let result = await stub.prober().probe(host: "probe.corp.example", rules: [rule], publicProbe: nil)
                    if case .failed = result {} else { t.fail("系统与本轮上游未同时通过时必须失败") }
                }
            },
            TestCase("接管后使用新公网名字验证 fake-ip，真实地址、混合地址与空答案均失败") { t in
                for values in [[fake], [IPv4("192.0.2.88")!], [fake, IPv4("192.0.2.88")!], []] {
                    let stub = Stub(); stub.publicAnswers = .resolved(values)
                    let result = await stub.prober().probe(host: "probe.corp.example", rules: [rule], publicProbe:
                        .init(host: "public.example", fakeIPRange: DNSGuardDaemonTests.fakeRange))
                    if values == [fake] { t.expectEqual(result, .answered([address])) }
                    else if case .failed = result {} else { t.fail("公网未完全返回 fake-ip 时必须失败") }
                    t.expect(stub.queries.last?.hasPrefix("dns-guard-") == true)
                    t.expect(stub.queries.last?.hasSuffix(".public.example") == true)
                }
            },
            TestCase("解析期间分域规则变化时，旧答案不能放行") { t in
                let stub = Stub(); stub.changeAfterQuery = true
                let result = await stub.prober().probe(host: "probe.corp.example", rules: [rule], publicProbe: nil)
                if case .failed = result {} else { t.fail("必须复核查询后的生效规则") }
            },
        ])
    }
}
