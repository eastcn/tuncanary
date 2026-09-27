import Foundation
import TunCanaryCore

/// DNS 守护进程：配置、判定和一次运行的编排。写入、读回、探针和状态文件都用桩对象，不改系统 DNS。全部使用合成数据。
enum DNSGuardDaemonTests {
    static let now = Date(timeIntervalSince1970: 1_790_424_000)
    static let target = ["192.0.2.53"]
    static let fakeRange = IPv4CIDR("198.18.0.0/16")!

    static func config(takeover: Bool = false, maxWrites: Int = 3, target: [String] = target) -> DNSGuardConfig {
        DNSGuardConfig(targetDNS: target, homeDirectory: "/Users/tester", proxyConfigDir: "/Users/tester/proxy",
                       connectedTakeover: .init(enabled: takeover, intranetProbeHost: takeover ? "probe.corp.example" : "",
                                                maxWritesPerTenMinutes: maxWrites))
    }

    static func sample(tun: Bool = true, vpn: VPNConnectionState = .disconnected, id: String = "S1",
                       type: String? = "IEEE80211", saved: [String] = [], port: Int? = 1053) -> DNSGuardSample {
        DNSGuardSample(tun: tun ? .running(interface: "utun1024") : .notRunning("配置关闭"), vpn: vpn,
                       service: .collected(.init(serviceID: id, type: type, savedDNS: saved)),
                       fakeIPRange: fakeRange, proxyDNSPort: port)
    }

    static func decide(_ first: DNSGuardSample, _ second: DNSGuardSample? = nil, config: DNSGuardConfig = config(),
                       state: DNSGuardState = DNSGuardState(), probe: DNSGuardProbeResult = .notRun) -> DNSGuardDecision {
        DNSGuardDecider.decide(first: first, second: second ?? first, config: config, state: state, probe: probe, now: now)
    }

    static func plan(_ current: [String], phase: DNSGuardPhase = .disconnected) -> DNSGuardDecision {
        .write(DNSGuardWritePlan(serviceID: "S1", phase: phase, currentDNS: current, targetDNS: target))
    }

    static var suite: TestSuite {
        TestSuite("Core.DNSGuardDaemon", configCases + decisionCases + sampleCases + runnerCases)
    }

    // MARK: - 配置

    static var configCases: [TestCase] {
        [
            TestCase("配置：必填字段、默认值与往返") { t in
                let minimal = #"{"targetDNS":["192.0.2.53"],"homeDirectory":"/Users/tester","proxyConfigDir":"/Users/tester/proxy"}"#
                let parsed = try DNSGuardConfig.parse(Data(minimal.utf8))
                t.expectEqual(parsed, config())
                t.expectEqual(parsed.allowedServiceTypes, ["IEEE80211", "Ethernet"])
                t.expectEqual(parsed.sampleDelaySeconds, 3)
                t.expectEqual(parsed.connectedTakeover, .init())
                t.expectEqual(try DNSGuardConfig.parse(config(takeover: true).encoded()), config(takeover: true))
                t.expectThrows(try DNSGuardConfig.parse(Data(#"{"targetDNS":["192.0.2.53"]}"#.utf8)))
                // 应用读取同一个文件时只取目标值和开关。
                t.expectEqual(try DNSGuardFileParser.parseConfig(config(takeover: true).encoded()),
                              DNSGuardConfigSummary(targetDNS: target, connectedTakeoverEnabled: true))
            },
            TestCase("配置：校验") { t in
                t.expectEqual(config().validate(), [])
                var bad = config(target: ["", "not-an-ip"])
                bad.allowedServiceTypes = ["IEEE80211", "PPP"]
                bad.homeDirectory = "relative"
                bad.sampleDelaySeconds = 60
                bad.connectedTakeover = .init(enabled: true, intranetProbeHost: "", maxWritesPerTenMinutes: 0)
                t.expectEqual(bad.validate(), [
                    "targetDNS 中的“not-an-ip”不是 IPv4 地址",
                    "allowedServiceTypes 不能包含 VPN 类服务“PPP”",
                    "homeDirectory 须为绝对路径",
                    "sampleDelaySeconds 须在 0 至 30 之间",
                    "connectedTakeover.maxWritesPerTenMinutes 须在 1 至 20 之间",
                    "启用连接期接管时，connectedTakeover.intranetProbeHost 须为有效域名",
                ])
                t.expectEqual(config(target: []).validate(), ["targetDNS 至少填写一个 IPv4 地址"])
            },
        ]
    }

    // MARK: - 判定

    static var decisionCases: [TestCase] {
        [
            TestCase("判定：TUN 未运行、主服务读取失败或两次不一致时跳过") { t in
                t.expectEqual(decide(sample(tun: false)), .skip(phase: nil, reason: "TUN 未运行（配置关闭）"))
                t.expectEqual(decide(sample(), sample(tun: false)), .skip(phase: nil, reason: "TUN 未运行（配置关闭）"))
                var failed = sample()
                failed.service = .failed(reason: "没有主网络服务")
                t.expectEqual(decide(failed), .skip(phase: nil, reason: "未能读取主网络服务（没有主网络服务）"))
                t.expectEqual(decide(sample(id: "S1"), sample(id: "S2")),
                              .skip(phase: nil, reason: "两次采样之间主网络服务发生变化"))
            },
            TestCase("判定：服务类型为 VPN、不在允许范围或未知时跳过") { t in
                t.expectEqual(decide(sample(type: "PPP")),
                              .skip(phase: nil, reason: "主网络服务的类型 PPP 不在允许写入的范围内"))
                t.expectEqual(decide(sample(type: "Bridge")),
                              .skip(phase: nil, reason: "主网络服务的类型 Bridge 不在允许写入的范围内"))
                var permissive = config()
                permissive.allowedServiceTypes = ["IEEE80211", "VPN"]
                t.expectEqual(decide(sample(type: "VPN"), config: permissive),
                              .skip(phase: nil, reason: "主网络服务的类型 VPN 不在允许写入的范围内"), "VPN 类服务永远不写")
                t.expectEqual(decide(sample(type: nil)), .skip(phase: nil, reason: "无法确认主网络服务的类型"))
                t.expectEqual(decide(sample(type: "Ethernet")), plan([]))
            },
            TestCase("判定：VPN 切换中、未确认、两次不一致时跳过；连接期未启用时跳过") { t in
                t.expectEqual(decide(sample(vpn: .switching)), .skip(phase: nil, reason: "VPN 正在切换"))
                t.expectEqual(decide(sample(vpn: .unconfirmed)), .skip(phase: nil, reason: "VPN 状态未确认"))
                t.expectEqual(decide(sample(vpn: .disconnected), sample(vpn: .connected)),
                              .skip(phase: nil, reason: "两次采样的 VPN 状态不一致"))
                t.expectEqual(decide(sample(vpn: .connected, saved: ["10.9.0.53"])),
                              .skip(phase: .connected, reason: "VPN 已连接，未启用连接期接管"))
            },
            TestCase("判定：断开期的保存值为空、DHCP 回落或 VPN 残留时写入") { t in
                t.expectEqual(decide(sample(saved: [])), plan([]))
                t.expectEqual(decide(sample(saved: ["192.168.1.1"])), plan(["192.168.1.1"]))
                t.expectEqual(decide(sample(saved: ["10.9.0.53", "10.9.0.54"])), plan(["10.9.0.53", "10.9.0.54"]))
                t.expectEqual(decide(sample(saved: ["192.0.2.53", "192.0.2.99"])), plan(["192.0.2.53", "192.0.2.99"]),
                              "含目标值但多了其他地址")
            },
            TestCase("判定：已等于目标值时只读；多个目标值忽略顺序") { t in
                t.expectEqual(decide(sample(saved: target)), .compliant(phase: .disconnected))
                let multi = config(target: ["192.0.2.53", "192.0.2.54"])
                t.expectEqual(decide(sample(saved: ["192.0.2.54", "192.0.2.53"]), config: multi),
                              .compliant(phase: .disconnected))
                t.expectEqual(decide(sample(saved: []), sample(saved: ["192.168.1.1"])),
                              .skip(phase: .disconnected, reason: "两次采样之间保存的 DNS 发生变化"))
            },
            TestCase("判定：退避期内不写，退避结束后再写") { t in
                let state = DNSGuardState(consecutiveFailures: 3, backoffUntil: now.addingTimeInterval(60))
                t.expectEqual(decide(sample(), state: state), .backoff(phase: .disconnected, until: now.addingTimeInterval(60)))
                t.expectEqual(decide(sample(saved: target), state: state), .compliant(phase: .disconnected),
                              "已符合时不必提退避")
                let expired = DNSGuardState(consecutiveFailures: 3, backoffUntil: now.addingTimeInterval(-1))
                t.expectEqual(decide(sample(), state: expired), plan([]))
            },
            TestCase("判定：连接期接管按内网探针结果决定") { t in
                let on = config(takeover: true)
                let connected = sample(vpn: .connected, saved: ["10.9.0.53"])
                t.expectEqual(decide(connected, config: on), .needsProbe(host: "probe.corp.example", port: 1053))
                t.expectEqual(decide(connected, config: on, probe: .answered([IPv4("10.20.0.8")!])),
                              plan(["10.9.0.53"], phase: .connected))
                t.expectEqual(decide(connected, config: on, probe: .answered([IPv4("198.18.0.40")!])),
                              .skip(phase: .connected, reason: "代理无法解析内网探针（返回 fake-ip）"))
                t.expectEqual(decide(connected, config: on, probe: .answered([])),
                              .skip(phase: .connected, reason: "代理无法解析内网探针（无记录）"))
                t.expectEqual(decide(connected, config: on, probe: .noResponse),
                              .skip(phase: .connected, reason: "代理无法解析内网探针（超时或无响应）"))
                t.expectEqual(decide(connected, config: on, probe: .failed("地址无效")),
                              .skip(phase: .connected, reason: "代理无法解析内网探针（地址无效）"))
                var noPort = connected
                noPort.proxyDNSPort = nil
                t.expectEqual(decide(noPort, config: on),
                              .skip(phase: .connected, reason: "代理配置缺少 DNS 端口，无法检查内网探针"))
                t.expectEqual(decide(sample(vpn: .connected, saved: target), config: on), .compliant(phase: .connected))
            },
            TestCase("判定：10 分钟内连接期写入达到上限时停用接管") { t in
                let on = config(takeover: true, maxWrites: 3)
                let connected = sample(vpn: .connected, saved: ["10.9.0.53"])
                let recent = [-500.0, -300, -10].map { now.addingTimeInterval($0) }
                t.expectEqual(decide(connected, config: on, state: DNSGuardState(connectedWrites: recent)), .suspendTakeover)
                let old = [-900.0, -300, -10].map { now.addingTimeInterval($0) }
                t.expectEqual(decide(connected, config: on, state: DNSGuardState(connectedWrites: old)),
                              .needsProbe(host: "probe.corp.example", port: 1053), "超过 10 分钟的不计")
                t.expectEqual(decide(connected, config: on, state: DNSGuardState(connectedTakeoverSuspended: true)),
                              .skip(phase: .connected, reason: "连接期接管已停用，等待 VPN 断开"))
            },
        ]
    }

    // MARK: - 由快照构造样本

    static var sampleCases: [TestCase] {
        [
            TestCase("样本：TUN 状态沿用应用的判定规则") { t in
                func make(_ snapshot: LocalSnapshot) -> DNSGuardSample {
                    let assessment = DNSRuleTests.evaluate(snapshot)
                    return DNSGuardSample.make(snapshot: snapshot, assessment: assessment, serviceType: "IEEE80211")
                }
                let running = make(DNSRuleTests.snapshot(saved: ["192.0.2.53"]))
                t.expectEqual(running.tun, .running(interface: "utun1024"))
                t.expectEqual(running.vpn, .disconnected)
                t.expectEqual(running.service, .collected(.init(serviceID: "S1", type: "IEEE80211", savedDNS: ["192.0.2.53"])))
                t.expectEqual(running.proxyDNSPort, 1053)
                t.expectEqual(running.fakeIPRange?.contains(IPv4("198.18.0.26")!), true)

                t.expectEqual(make(DNSRuleTests.snapshot(saved: [], tunOn: false)).tun, .notRunning("配置关闭"))
                var noInterface = DNSRuleTests.snapshot(saved: [])
                noInterface.interfaces = .collected([VPNTests.overlay])
                t.expectEqual(make(noInterface).tun, .notRunning("配置开启，但 TUN 未生效"))
                var stopped = DNSRuleTests.snapshot(saved: [])
                stopped.mihomoRunning = .collected(false)
                t.expectEqual(make(stopped).tun, .notRunning("配置开启，但 TUN 未生效"))

                let decision = DNSGuardDecider.decide(first: make(noInterface), second: make(noInterface),
                                                      config: config(), state: DNSGuardState(), now: now)
                t.expectEqual(decision, .skip(phase: nil, reason: "TUN 未运行（配置开启，但 TUN 未生效）"))
            },
        ]
    }

    // MARK: - 一次运行

    final class Stubs: DNSGuardSampling, DNSGuardWriting, DNSGuardProbing, DNSGuardStateStoring, @unchecked Sendable {
        private let lock = NSLock()
        var samples: [DNSGuardSample] = []
        var writeOutcome: DNSGuardWriteOutcome = .written
        /// 依次返回；用完后重复最后一个。第一个用于写入前复读。
        var readBacks: [DNSGuardReadBack] = []
        var probeResult: DNSGuardProbeResult = .answered([IPv4("10.20.0.8")!])
        var state = DNSGuardState()
        var events: [DNSGuardEvent] = []
        var writes: [DNSGuardWritePlan] = []
        var probes = 0
        private var readIndex = 0

        func sample() async -> DNSGuardSample { nextSample() }

        private func nextSample() -> DNSGuardSample {
            lock.lock(); defer { lock.unlock() }
            return samples.count > 1 ? samples.removeFirst() : samples[0]
        }

        func write(_ plan: DNSGuardWritePlan) -> DNSGuardWriteOutcome {
            lock.lock(); defer { lock.unlock() }
            writes.append(plan)
            return writeOutcome
        }

        func readBack(serviceID: String) -> DNSGuardReadBack {
            lock.lock(); defer { lock.unlock() }
            let value = readBacks[min(readIndex, readBacks.count - 1)]
            readIndex += 1
            return value
        }

        func probe(host: String, port: Int) async -> DNSGuardProbeResult { recordProbe() }

        private func recordProbe() -> DNSGuardProbeResult {
            lock.lock(); defer { lock.unlock() }
            probes += 1
            return probeResult
        }

        func loadState() -> DNSGuardState { lock.lock(); defer { lock.unlock() }; return state }
        func saveState(_ state: DNSGuardState) throws { lock.lock(); self.state = state; lock.unlock() }
        func appendEvent(_ event: DNSGuardEvent) throws { lock.lock(); events.append(event); lock.unlock() }

        func resetReads(_ values: [DNSGuardReadBack]) {
            lock.lock(); readBacks = values; readIndex = 0; lock.unlock()
        }
    }

    final class Sleeps: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [TimeInterval] = []
        func record(_ value: TimeInterval) { lock.lock(); values.append(value); lock.unlock() }
    }

    static func read(saved: [String]?, resolver: [String]?, id: String = "S1") -> DNSGuardReadBack {
        DNSGuardReadBack(primaryServiceID: id, savedDNS: saved, resolverDNS: resolver)
    }

    static func runner(_ stubs: Stubs, config: DNSGuardConfig = config(), dryRun: Bool = false,
                       sleeps: Sleeps = Sleeps(), at date: Date = now) -> DNSGuardRunner {
        DNSGuardRunner(config: config, sampler: stubs, writer: stubs, prober: stubs, store: stubs,
                       redactor: Redactor(homeDirectory: "/Users/tester"), dryRun: dryRun,
                       now: { date }, sleep: { sleeps.record($0) })
    }

    static var runnerCases: [TestCase] {
        [
            TestCase("运行：已符合时不写入，相同结果不重复记事件") { t in
                let stubs = Stubs()
                stubs.samples = [sample(saved: target)]
                let sleeps = Sleeps()
                let report = await runner(stubs, sleeps: sleeps).run()
                t.expectEqual(report.decision, .compliant(phase: .disconnected))
                t.expect(!report.attemptedWrite)
                t.expectEqual(sleeps.values, [3], "两次采样之间等待 sampleDelaySeconds")
                t.expectEqual(stubs.writes, [])
                t.expectEqual(stubs.events.map(\.outcome), [.compliant])
                t.expectEqual(stubs.state.lastRun?.outcome, .compliant)

                _ = await runner(stubs, at: now.addingTimeInterval(30)).run()
                t.expectEqual(stubs.events.count, 1, "结果没变，只更新状态文件")
                t.expectEqual(stubs.state.lastRun?.date, now.addingTimeInterval(30))
            },
            TestCase("运行：VPN 切换中时在同一次运行里重新采样") { t in
                let stubs = Stubs()
                stubs.samples = [sample(vpn: .connected, saved: ["10.9.0.53"]), sample(vpn: .disconnected, saved: []),
                                 sample(vpn: .disconnected, saved: [])]
                stubs.readBacks = [read(saved: [], resolver: nil), read(saved: target, resolver: target)]
                let sleeps = Sleeps()
                let report = await runner(stubs, sleeps: sleeps).run()
                t.expectEqual(sleeps.values, [3, 5], "第一对不一致，等 5 秒再采一次")
                t.expectEqual(report.event, DNSGuardEvent(date: now, phase: .disconnected, outcome: .written))
                t.expectEqual(stubs.events.map(\.outcome), [.written])

                let unstable = Stubs()
                unstable.samples = [sample(vpn: .unconfirmed)]
                let waits = Sleeps()
                let skipped = await runner(unstable, sleeps: waits).run()
                t.expectEqual(waits.values, [3, 5, 5, 5], "最多重试 3 次")
                t.expectEqual(skipped.event.reason, "VPN 状态未确认")
                t.expectEqual(unstable.writes, [])

                t.expect(DNSGuardDecider.isTransition(sample(saved: []), sample(saved: ["192.168.1.1"])))
                t.expect(!DNSGuardDecider.isTransition(sample(tun: false), sample()), "TUN 状态变化不算 VPN 切换")
                t.expect(!DNSGuardDecider.isTransition(sample(id: "S1"), sample(id: "S2", saved: ["192.168.1.1"])))
            },
            TestCase("运行：写入后读回一致才算成功") { t in
                let stubs = Stubs()
                stubs.samples = [sample(saved: [])]
                stubs.readBacks = [read(saved: [], resolver: ["192.168.1.1"]),
                                   read(saved: target, resolver: ["192.168.1.1"]),
                                   read(saved: target, resolver: target)]
                stubs.state = DNSGuardState(consecutiveFailures: 2)
                let sleeps = Sleeps()
                let report = await runner(stubs, sleeps: sleeps).run()
                t.expect(report.attemptedWrite)
                t.expectEqual(stubs.writes, [DNSGuardWritePlan(serviceID: "S1", phase: .disconnected,
                                                              currentDNS: [], targetDNS: target)])
                t.expectEqual(report.event.outcome, .written)
                t.expectEqual(sleeps.values, [3, 1], "第一次读回不一致，等 1 秒再读")
                t.expectEqual(stubs.state.consecutiveFailures, 0)
                t.expectEqual(stubs.state.lastWrite, report.event)
                t.expectEqual(stubs.events, [report.event])
                t.expectEqual(stubs.state.connectedWrites, [], "断开期写入不计入连接期次数")
            },
            TestCase("运行：写入前复读发现变化时放弃，不计失败") { t in
                let stubs = Stubs()
                stubs.samples = [sample(saved: [])]
                stubs.readBacks = [read(saved: ["10.9.0.53"], resolver: nil)]
                var report = await runner(stubs).run()
                t.expectEqual(stubs.writes, [])
                t.expectEqual(report.event.outcome, .skipped)
                t.expectEqual(report.event.reason, "写入前复读发现保存的 DNS 已变化，放弃写入")

                stubs.resetReads([read(saved: [], resolver: nil, id: "S2")])
                report = await runner(stubs).run()
                t.expectEqual(report.event.reason, "写入前复读发现主网络服务已变化，放弃写入")

                stubs.resetReads([read(saved: [], resolver: nil)])
                stubs.writeOutcome = .changed("写入前复读发现保存的 DNS 已变化，放弃写入")
                report = await runner(stubs).run()
                t.expectEqual(stubs.writes.count, 1, "加锁后复读由写入方完成")
                t.expectEqual(report.event.outcome, .skipped)
                t.expectEqual(stubs.state.consecutiveFailures, 0)
            },
            TestCase("运行：写入失败、读回不一致累计失败，3 次后退避") { t in
                let stubs = Stubs()
                stubs.samples = [sample(saved: [])]
                stubs.readBacks = [read(saved: [], resolver: nil)]
                stubs.writeOutcome = .failed("无法锁定网络设置（权限不足）")
                var report = await runner(stubs).run()
                t.expectEqual(report.event, DNSGuardEvent(date: now, phase: .disconnected, outcome: .writeFailed,
                                                          reason: "无法锁定网络设置（权限不足）"))
                t.expectEqual(stubs.state.consecutiveFailures, 1)

                stubs.writeOutcome = .written
                stubs.resetReads([read(saved: [], resolver: nil), read(saved: target, resolver: ["192.168.1.1"])])
                report = await runner(stubs).run()
                t.expectEqual(report.event.outcome, .verifyFailed)
                t.expectEqual(report.event.reason, "系统默认解析器为 192.x.x.x", "读回原因经过脱敏")
                t.expectEqual(stubs.state.consecutiveFailures, 2)
                t.expectNil(stubs.state.backoffUntil)

                stubs.resetReads([read(saved: [], resolver: nil), read(saved: [], resolver: nil)])
                report = await runner(stubs).run()
                t.expectEqual(report.event.reason, "读回的保存值为 空")
                t.expectEqual(stubs.state.consecutiveFailures, 3)
                t.expectEqual(stubs.state.backoffUntil, now.addingTimeInterval(600))
                t.expectEqual(stubs.events.count, 3, "每次写入都记事件")

                let writes = stubs.writes.count
                report = await runner(stubs, at: now.addingTimeInterval(60)).run()
                t.expectEqual(report.event.outcome, .backoff)
                t.expectEqual(stubs.writes.count, writes, "退避期内不写")

                stubs.resetReads([read(saved: [], resolver: nil), read(saved: target, resolver: target)])
                report = await runner(stubs, at: now.addingTimeInterval(601)).run()
                t.expectEqual(report.event.outcome, .written)
                t.expectEqual(stubs.state.consecutiveFailures, 0)
                t.expectNil(stubs.state.backoffUntil)
            },
            TestCase("运行：连接期写入达到上限后停用，VPN 断开后恢复") { t in
                let stubs = Stubs()
                let on = config(takeover: true, maxWrites: 2)
                stubs.samples = [sample(vpn: .connected, saved: ["10.9.0.53"])]
                for index in 0..<2 {
                    stubs.resetReads([read(saved: ["10.9.0.53"], resolver: nil), read(saved: target, resolver: target)])
                    let report = await runner(stubs, config: on, at: now.addingTimeInterval(Double(index * 60))).run()
                    t.expectEqual(report.event, DNSGuardEvent(date: now.addingTimeInterval(Double(index * 60)),
                                                              phase: .connected, outcome: .written))
                }
                t.expectEqual(stubs.probes, 2)
                t.expectEqual(stubs.state.connectedWrites.count, 2)

                var report = await runner(stubs, config: on, at: now.addingTimeInterval(120)).run()
                t.expectEqual(report.decision, .suspendTakeover)
                t.expect(stubs.state.connectedTakeoverSuspended)
                t.expectEqual(stubs.events.last?.outcome, .takeoverSuspended)

                report = await runner(stubs, config: on, at: now.addingTimeInterval(180)).run()
                t.expectEqual(report.event.reason, "连接期接管已停用，等待 VPN 断开")
                t.expectEqual(stubs.writes.count, 2)

                stubs.samples = [sample(vpn: .disconnected, saved: target)]
                report = await runner(stubs, config: on, at: now.addingTimeInterval(240)).run()
                t.expectEqual(report.decision, .compliant(phase: .disconnected))
                t.expect(!stubs.state.connectedTakeoverSuspended)
                t.expectEqual(stubs.state.connectedWrites, [])
            },
            TestCase("运行：内网探针失败时不写入") { t in
                let stubs = Stubs()
                stubs.samples = [sample(vpn: .connected, saved: ["10.9.0.53"])]
                stubs.probeResult = .answered([IPv4("198.18.0.40")!])
                let report = await runner(stubs, config: config(takeover: true)).run()
                t.expectEqual(report.event.reason, "代理无法解析内网探针（返回 fake-ip）")
                t.expectEqual(stubs.writes, [])
                t.expectNotContains(stubs.events.map(\.text).joined(), "probe.corp.example")
            },
            TestCase("运行：试运行不写入，不更新状态文件") { t in
                let stubs = Stubs()
                stubs.samples = [sample(saved: ["10.9.0.53"])]
                let report = await runner(stubs, dryRun: true).run()
                t.expectEqual(report.decision, plan(["10.9.0.53"]))
                t.expectEqual(report.event.reason, "试运行：将把 10.x.x.x 改为 192.0.2.53")
                t.expectEqual(stubs.writes, [])
                t.expectEqual(stubs.events, [])
                t.expectEqual(stubs.state, DNSGuardState())
            },
            TestCase("状态文件：原子写入、权限 0644、事件最多 200 条") { t in
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tuncanary-guard-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let store = DNSGuardStateStore(paths: DNSGuardPaths(root: root.path))
                t.expectEqual(store.loadState(), DNSGuardState(), "文件不存在时为空状态")
                let event = DNSGuardEvent(date: now, phase: .disconnected, outcome: .written)
                let state = DNSGuardState(lastRun: event, lastWrite: event, connectedWrites: [now])
                try store.saveState(state)
                t.expectEqual(store.loadState(), state)
                let attributes = try FileManager.default.attributesOfItem(atPath: store.paths.stateFile)
                t.expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)

                for index in 0..<205 {
                    try store.appendEvent(DNSGuardEvent(date: now.addingTimeInterval(Double(index)), outcome: .compliant))
                }
                let data = try Data(contentsOf: URL(fileURLWithPath: store.paths.eventLogFile))
                let events = DNSGuardFileParser.parseEvents(data, limit: 1000)
                t.expectEqual(events.count, DNSGuardStateStore.maxEvents)
                t.expectEqual(events.first?.date, now.addingTimeInterval(5))
            },
        ]
    }
}
