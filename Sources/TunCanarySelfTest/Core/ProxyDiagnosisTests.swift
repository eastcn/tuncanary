import Foundation
import TunCanaryCore

/// 代理日志解析与诊断说明。日志内容为虚构数据。
enum ProxyDiagnosisTests {
    static var suite: TestSuite {
        TestSuite("Core.ProxyDiagnosis", [
            TestCase("解析匹配记录：进程、目标、规则和出站链") { t in
                let line = "[TCP] 198.18.0.1:50141(TunCanary) --> github.com:443 match DomainKeyword(github) using 节点选择[HK 01]"
                let connection = try t.require(ProxyLogConnection.parse(line))
                t.expectEqual(connection.network, "TCP")
                t.expectEqual(connection.source, "198.18.0.1")
                t.expectEqual(connection.process, "TunCanary")
                t.expectEqual(connection.host, "github.com")
                t.expectEqual(connection.port, 443)
                t.expectEqual(connection.rule, "DomainKeyword(github)")
                t.expectEqual(connection.chain, "节点选择[HK 01]")
                t.expectEqual(connection.node, "HK 01")
                t.expect(!connection.isDirect)
                t.expectNil(connection.error)

                let direct = try t.require(ProxyLogConnection.parse(
                    "[TCP] 127.0.0.1:50143(Google Chrome Helper) --> www.example.cn:443 match DomainSuffix(example.cn) using 直连[DIRECT]"))
                t.expectEqual(direct.process, "Google Chrome Helper")
                t.expect(direct.isDirect)
            },
            TestCase("解析拨号失败记录：带规则和不带规则两种") { t in
                let withRule = try t.require(ProxyLogConnection.parse(
                    "[TCP] dial 节点选择 (match DomainKeyword/github) 198.18.0.1:50141(TunCanary) --> github.com:443 error: connect failed: i/o timeout"))
                t.expectEqual(withRule.chain, "节点选择")
                t.expectEqual(withRule.rule, "DomainKeyword(github)")
                t.expectEqual(withRule.process, "TunCanary")
                t.expectEqual(withRule.error, "connect failed: i/o timeout")

                let noRule = try t.require(ProxyLogConnection.parse(
                    "[TCP] dial Example Group 198.18.0.1:50200(Some App 2) --> example.com:443 error: EOF"))
                t.expectEqual(noRule.chain, "Example Group")
                t.expectEqual(noRule.rule, "")
                t.expectEqual(noRule.process, "Some App 2")
                t.expectEqual(noRule.host, "example.com")
            },
            TestCase("不是连接记录时返回 nil") { t in
                t.expectNil(ProxyLogConnection.parse("Start initial configuration in progress"))
                t.expectNil(ProxyLogConnection.parse("[TCP] garbage"))
                t.expectNil(ProxyLogConnection.parse("[DNS] resolve github.com"))
            },
            TestCase("诊断说明：经 TUN、经系统代理、直连和不可读") { t in
                let connection = ProxyLogConnection(network: "TCP", source: "198.18.0.1", process: "TunCanary",
                                                    host: "github.com", port: 443, rule: "DomainKeyword(github)",
                                                    chain: "节点选择[HK 01]", error: "i/o timeout")
                let failed = SiteDiagnosis(siteID: "github", siteName: "GitHub", diagnosedAt: Date(), manual: false,
                                           outcome: .failure(.tlsError, detail: "TLS 失败，错误码 -1200，底层 -9806"),
                                           route: .proxied(connection, viaTun: true), nodeDelay: .failed(reason: "超时"))
                t.expectEqual(failed.lines, [
                    "复测：TLS 错误（TLS 失败，错误码 -1200，底层 -9806）",
                    "代理：经 TUN，规则 DomainKeyword(github) → 节点选择[HK 01]",
                    "代理报错：i/o timeout",
                    "节点延迟：超时",
                ])
                var proxy = failed
                proxy.route = .proxied(connection, viaTun: false)
                t.expectContains(proxy.lines[1], "经系统代理")
                var missing = failed
                missing.route = .notInProxy(tunRunning: true)
                missing.nodeDelay = nil
                t.expectEqual(missing.lines[1], "代理：日志中没有这次连接，连接没有进入代理")
                missing.route = .notInProxy(tunRunning: false)
                t.expectEqual(missing.lines[1], "代理：未经过代理（直连）")
                missing.route = .unavailable(reason: "未找到 Clash Verge Rev 的控制接口")
                t.expectEqual(missing.lines[1], "代理：无法读取代理日志（未找到 Clash Verge Rev 的控制接口）")
                let ok = SiteDiagnosis(siteID: "github", siteName: "GitHub", diagnosedAt: Date(), manual: true,
                                       outcome: .http(status: 200, latency: 0.2), route: .notInProxy(tunRunning: false))
                t.expectEqual(ok.lines.first, "复测：可达 200 ms")
            },
        ])
    }
}
