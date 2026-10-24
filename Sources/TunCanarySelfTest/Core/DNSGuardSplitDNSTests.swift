import Foundation
import TunCanaryCore

enum DNSGuardSplitDNSTests {
    static let rule = DNSGuardSplitDNSRule(domain: "corp.example", servers: ["10.9.0.53", "10.9.0.54"])

    static func config() -> DNSGuardConfig {
        var value = DNSGuardDaemonTests.config(takeover: true)
        value.connectedTakeover.probeMode = .systemSplitDNS
        value.connectedTakeover.splitDNSRules = [rule]
        return value
    }

    static var suite: TestSuite {
        TestSuite("Core.DNSGuardSplitDNS", runnerCases + [
            TestCase("回归：已连接且分域解析通过时接管，不要求代理解析内网") { t in
                let sample = DNSGuardDaemonTests.sample(vpn: .connected, saved: ["10.9.0.53"], port: nil)
                let on = config()
                t.expectEqual(on.validate(), [])
                t.expectEqual(DNSGuardDaemonTests.decide(sample, config: on),
                              .needsSystemSplitProbe(host: "probe.corp.example", publicProbe: nil))
                t.expectEqual(DNSGuardDaemonTests.decide(sample, config: on,
                    probe: .answered([IPv4("10.20.0.8")!])),
                    DNSGuardDaemonTests.plan(["10.9.0.53"], phase: .connected))
            },
            TestCase("目标值已符合也须验证分域和公网，不能直接报告健康") { t in
                let sample = DNSGuardDaemonTests.sample(vpn: .connected, saved: DNSGuardDaemonTests.target)
                t.expectEqual(DNSGuardDaemonTests.decide(sample, config: config()),
                    .needsSystemSplitProbe(host: "probe.corp.example", publicProbe: .init(
                        host: PulseConstants.canaryHost, fakeIPRange: DNSGuardDaemonTests.fakeRange)))
                t.expectEqual(DNSGuardDaemonTests.decide(sample, config: config(),
                    probe: .answered([IPv4("10.20.0.8")!])), .compliant(phase: .connected))
                if case .skip = DNSGuardDaemonTests.decide(sample, config: config(), probe: .noResponse) {} else {
                    t.fail("系统解析未通过时不得报告已符合")
                }
            },
            TestCase("分域模式：缺规则、未知模式及公网探针落入分域时拒绝配置") { t in
                var on = config()
                t.expectEqual(try DNSGuardConfig.parse(on.encoded()), on)
                on.connectedTakeover.splitDNSRules = []
                t.expect(!on.validate().isEmpty)
                on = config()
                on.connectedTakeover.publicProbeHost = "www.corp.example"
                t.expect(!on.validate().isEmpty)
                let invalid = String(decoding: config().encoded(), as: UTF8.self)
                    .replacingOccurrences(of: "systemSplitDNS", with: "unknown")
                t.expectThrows(try DNSGuardConfig.parse(Data(invalid.utf8)))
            },
            TestCase("持久化规则：核验地址、域名和端口，不接受其他解析模式") { t in
                t.expectNil(rule.fileProblem("# 合成规则\nnameserver 10.9.0.54\nnameserver 10.9.0.53\n"))
                t.expect(rule.fileProblem("nameserver 10.9.0.99") != nil)
                t.expect(rule.fileProblem("domain other.example\nnameserver 10.9.0.53") != nil)
                t.expect(rule.fileProblem("port 5353\nnameserver 10.9.0.53") != nil)
                t.expect(rule.fileProblem("options mdns\nnameserver 10.9.0.53") != nil)
                t.expect(!rule.matches("notcorp.example"))
                t.expect(rule.matches("PROBE.CORP.EXAMPLE."))
            },
            TestCase("生效规则：必须为普通分域，拒绝缺失、冲突、地址漂移和更具体覆盖") { t in
                let good = Resolver(isScoped: false, number: 2, domain: rule.domain, nameservers: rule.servers)
                func problem(_ values: [Resolver]) -> String? {
                    DNSGuardSplitDNSVerifier.problem(rules: [rule], resolvers: values, host: "probe.corp.example")
                }
                t.expectNil(problem([good]))
                t.expect(problem([]) != nil)
                var scoped = good; scoped.isScoped = true
                t.expect(problem([scoped]) != nil)
                t.expect(problem([good, good]) != nil)
                var changed = good; changed.nameservers = ["192.0.2.53"]
                t.expect(problem([changed]) != nil)
                let override = Resolver(isScoped: false, number: 3, domain: "probe.corp.example",
                                        nameservers: ["192.0.2.99"])
                t.expect(problem([good, override]) != nil)
            },
        ])
    }

    static var runnerCases: [TestCase] {
        typealias D = DNSGuardDaemonTests
        let old = ["10.9.0.53"]
        let target = D.target
        return [
            TestCase("真实编排：代理探针失败但系统分域通过，写入后再验证内网与公网") { t in
                let stub = D.Stubs()
                stub.samples = [D.sample(vpn: .connected, saved: old, port: nil)]
                stub.probeResult = .noResponse
                stub.readBacks = [D.read(saved: old, resolver: old), D.read(saved: target, resolver: target)]
                let report = await D.runner(stub, config: config()).run()
                t.expectEqual(report.event.outcome, .written)
                t.expectEqual(stub.probes, 0, "系统分域模式不调用代理内网探针")
                t.expectEqual(stub.systemProbes, 2)
                t.expectEqual(stub.publicProbes, 1)
                t.expectEqual(stub.writes.count, 1)
            },
            TestCase("写后内网或公网复验失败，恢复原 DNS 后仍报告验证失败") { t in
                let stub = D.Stubs()
                stub.samples = [D.sample(vpn: .connected, saved: old)]
                stub.systemProbeSequence = [.answered([IPv4("10.20.0.8")!]), .failed("公网系统解析未返回代理 fake-ip")]
                stub.readBacks = [D.read(saved: old, resolver: old), D.read(saved: target, resolver: target),
                                  D.read(saved: target, resolver: target), D.read(saved: old, resolver: old)]
                let report = await D.runner(stub, config: config()).run()
                t.expectEqual(report.event.outcome, .verifyFailed)
                t.expect(report.event.reason?.contains("已恢复并读回写入前的 DNS") == true)
                t.expectEqual(stub.writes.count, 2)
                t.expectEqual(stub.writes.last?.currentDNS, target)
                t.expectEqual(stub.writes.last?.targetDNS, old)
                t.expectEqual(stub.state.consecutiveFailures, 1)
                t.expectEqual(stub.state.connectedWrites.count, 2)
            },
            TestCase("恢复前其他进程改动 DNS 时不覆盖") { t in
                let stub = D.Stubs()
                stub.samples = [D.sample(vpn: .connected, saved: old)]
                stub.systemProbeSequence = [.answered([IPv4("10.20.0.8")!]), .failed("合成失败")]
                stub.readBacks = [D.read(saved: old, resolver: old), D.read(saved: target, resolver: target),
                                  D.read(saved: ["192.0.2.99"], resolver: ["192.0.2.99"])]
                let report = await D.runner(stub, config: config()).run()
                t.expectEqual(report.event.outcome, .verifyFailed)
                t.expectEqual(stub.writes.count, 1)
                t.expect(report.event.reason?.contains("未覆盖其他进程的修改") == true)
            },
            TestCase("恢复失败或读回未确认时，不能声称已恢复") { t in
                for writeFails in [true, false] {
                    let stub = D.Stubs()
                    stub.samples = [D.sample(vpn: .connected, saved: old)]
                    stub.systemProbeSequence = [.answered([IPv4("10.20.0.8")!]), .failed("合成失败")]
                    stub.readBacks = [D.read(saved: old, resolver: old), D.read(saved: target, resolver: target)]
                    if writeFails { stub.writeSequence = [.written, .failed("合成写入失败")] }
                    let report = await D.runner(stub, config: config()).run()
                    t.expectEqual(report.event.outcome, .verifyFailed)
                    t.expect(report.event.reason?.contains("已恢复并读回") == false)
                    t.expect(report.event.reason?.contains(writeFails ? "恢复写入前 DNS 失败" : "读回未确认") == true)
                    t.expectEqual(stub.state.connectedWrites.count, 2)
                }
            },
            TestCase("默认解析器读回不符也会恢复；主服务变化时不恢复和不报成功") { t in
                for changedService in [false, true] {
                    let stub = D.Stubs()
                    stub.samples = [D.sample(vpn: .connected, saved: old)]
                    let wrong = D.read(saved: target, resolver: changedService ? target : old,
                                       id: changedService ? "S2" : "S1")
                    stub.readBacks = [D.read(saved: old, resolver: old)]
                        + Array(repeating: wrong, count: DNSGuardRunner.readBackAttempts + 1)
                        + [D.read(saved: old, resolver: old)]
                    let report = await D.runner(stub, config: config()).run()
                    t.expectEqual(report.event.outcome, .verifyFailed)
                    t.expectEqual(stub.writes.count, changedService ? 1 : 2)
                    t.expectEqual(stub.systemProbes, 1, "读回失败不执行写后探针")
                    t.expect(report.event.reason?.contains(changedService ? "未覆盖其他进程" : "已恢复并读回") == true)
                }
            },
            TestCase("系统查询期间 VPN 断开，不使用旧探针结果接管") { t in
                let stub = D.Stubs()
                let connected = D.sample(vpn: .connected, saved: old)
                stub.samples = [connected, connected, D.sample(vpn: .disconnected, saved: old)]
                let report = await D.runner(stub, config: config()).run()
                t.expectEqual(report.event.outcome, .skipped)
                t.expectEqual(stub.writes, [])
                t.expectEqual(stub.systemProbes, 1)
            },
            TestCase("目标已符合仍核验两条路径；试运行绝不写入与更新状态") { t in
                let stub = D.Stubs()
                stub.samples = [D.sample(vpn: .connected, saved: target)]
                let report = await D.runner(stub, config: config()).run()
                t.expectEqual(report.event.outcome, .compliant)
                t.expectEqual(stub.publicProbes, 1)
                t.expectEqual(stub.writes, [])
                let dry = D.Stubs()
                dry.samples = [D.sample(vpn: .connected, saved: old)]
                let simulated = await D.runner(dry, config: config(), dryRun: true).run()
                t.expect(!simulated.attemptedWrite)
                t.expectEqual(dry.writes, [])
                t.expectEqual(dry.events, [])
                t.expectNil(dry.state.lastRun)
            },
        ]
    }

}
