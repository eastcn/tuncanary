import Foundation
import TunCanaryCore

/// 判定表每一行至少一个用例，另加证据冲突、宽限期、有线、配置不可读、Tailscale、进程匹配等。
enum LocalEvaluatorTests {
    typealias F = FixtureLoader

    static var suite: TestSuite {
        TestSuite("Core.LocalEvaluator", [
            // MARK: 判定表

            TestCase("表1 绿：VPN 断开，TUN 运行，DNS 与预期一致") { t in
                let result = F.evaluate(try F.snapshot(.a))
                t.expectEqual(result.card(.primaryDNS)?.severity, .ok)
                t.expectEqual(result.severity, .ok)
            },
            TestCase("表2 绿：VPN 已连接，保存值为状态文件中的 VPN DNS") { t in
                let result = F.evaluate(try F.snapshot(.b))
                t.expectEqual(result.card(.primaryDNS)?.severity, .ok)
                t.expectEqual(result.card(.primaryDNS)?.hint, "连接期状态；启用 VPN 站点探测")
                // 两个 VPN DNS 都写入也算。
                let both = F.withSavedDNS(try F.snapshot(.b), ["10.9.0.54", "10.9.0.53"])
                t.expectEqual(F.evaluate(both).severity, .ok)
            },
            TestCase("表3 黄：VPN 已连接，但 DNS 不是 VPN 下发的 DNS") { t in
                for saved in [["119.29.29.29"], [], ["10.9.0.53", "8.8.8.8"]] {
                    let result = F.evaluate(F.withSavedDNS(try F.snapshot(.b), saved))
                    let dns = try t.require(result.card(.primaryDNS))
                    t.expectEqual(dns.severity, .warning, "\(saved)")
                    t.expectEqual(dns.faultKey, .dnsVPNMissing)
                    t.expectEqual(dns.hint, "VPN DNS 未生效，VPN 域名可能无法解析")
                    t.expectEqual(result.faultKeys, [.dnsVPNMissing])
                }
            },
            TestCase("表4 红：VPN 断开，TUN 运行，DNS 为空、残留 VPN DNS 或其他值") { t in
                let empty = F.evaluate(try F.snapshot(.c))
                t.expectEqual(empty.faultKeys, [.dnsNotRestored])

                // VPN 客户端异常退出，没有清理 DNS：VPN DNS 残留。
                var residual = F.withSavedDNS(try F.snapshot(.c), ["10.9.0.53"])
                residual.globalDNS = .collected(["10.9.0.53"])
                let residualResult = F.evaluate(residual)
                t.expectEqual(residualResult.severity, .critical)
                t.expectEqual(residualResult.faultKeys, [.dnsNotRestored])
                t.expect(residualResult.card(.primaryDNS)!.evidence.contains("保存值：10.9.0.53（残留的 VPN DNS）"),
                         "\(residualResult.card(.primaryDNS)!.evidence)")

                let other = F.evaluate(F.withSavedDNS(try F.snapshot(.a), ["8.8.8.8"]))
                t.expectEqual(other.severity, .critical)
                t.expect(other.card(.primaryDNS)!.evidence.first!.contains("与预期 119.29.29.29 不一致"))
            },
            TestCase("表5 红：DNS 与预期一致，但系统解析返回真实地址") { t in
                var snapshot = try F.snapshot(.a)
                snapshot.canary = .resolved([F.realAnswer])
                let result = F.evaluate(snapshot)
                let dns = try t.require(result.card(.primaryDNS))
                t.expectEqual(dns.severity, .critical)
                t.expectEqual(dns.conclusion, "系统 DNS 未经过代理")
                t.expectEqual(dns.faultKey, .dnsBypassProxy)
                t.expect(dns.evidence.contains("系统解析 www.google.com 返回真实地址 142.250.0.1"))
                // 未测或解析失败时不触发。
                snapshot.canary = .notTested
                t.expectEqual(F.evaluate(snapshot).severity, .ok)
                snapshot.canary = .failed(reason: "超时")
                t.expectEqual(F.evaluate(snapshot).severity, .ok)
            },
            TestCase("AAAA 只作证据：不改变严重程度、不产生故障") { t in
                let base = try F.snapshot(.a)
                let baseline = F.evaluate(base)
                let baseDNS = try t.require(baseline.card(.primaryDNS))
                t.expect(!baseDNS.evidence.contains { $0.contains("AAAA") }, "未查询时没有 AAAA 证据")

                func dnsCard(_ result: CanaryIPv6Result, range6: String? = nil) throws -> (StatusCard, LocalAssessment) {
                    var snapshot = base
                    snapshot.canaryIPv6 = result
                    if let range6 {
                        var config = try t.require(snapshot.clashConfig.value)
                        config.fakeIPRange6 = IPv6CIDR(range6)
                        snapshot.clashConfig = .collected(config)
                    }
                    let assessment = F.evaluate(snapshot)
                    return (try t.require(assessment.card(.primaryDNS)), assessment)
                }
                let cases: [(CanaryIPv6Result, String?, String)] = [
                    (.noRecord, nil, "系统解析 www.google.com 无 AAAA 记录"),
                    (.failed(reason: "超时"), nil, "系统解析 www.google.com 的 AAAA 记录失败：超时"),
                    (.resolved([IPv6("fdfe:dcba:9876::1a")!]), "fdfe:dcba:9876::1/64",
                     "系统解析 www.google.com 的 AAAA 返回 fake-ip fdfe:dcba:9876::1a"),
                    (.resolved([IPv6("2001:db8::1")!]), nil,
                     "系统解析 www.google.com 的 AAAA 返回真实 IPv6 地址 2001:db8::1（仅供参考：IPv6 流量可能未经过代理）"),
                    (.resolved([IPv6("fd00::1")!]), nil, "系统解析 www.google.com 的 AAAA 返回 fd00::1"),
                ]
                for (result, range6, expected) in cases {
                    let (dns, assessment) = try dnsCard(result, range6: range6)
                    t.expect(dns.evidence.contains(expected), "\(result)：\(dns.evidence)")
                    t.expectEqual(dns.severity, baseDNS.severity)
                    t.expectEqual(assessment.severity, baseline.severity)
                    t.expectEqual(assessment.faults.map(\.key), baseline.faults.map(\.key))
                }

                // TUN 关闭时不给 AAAA 证据。
                var off = try F.snapshot(.a)
                off.clashConfig = .collected(F.clashConfig(tunOn: false))
                off.canaryIPv6 = .resolved([IPv6("2001:db8::1")!])
                let offDNS = try t.require(F.evaluate(off).card(.primaryDNS))
                t.expect(!offDNS.evidence.contains { $0.contains("AAAA") })
            },
            TestCase("表6 黄：TUN 关闭，但 DNS 仍含 119.29.29.29") { t in
                var snapshot = try F.snapshot(.a)
                snapshot.clashConfig = .collected(F.clashConfig(tunOn: false))
                snapshot.mihomoDNS = .notApplicable
                let result = F.evaluate(snapshot)
                t.expectEqual(result.tunState, .off)
                t.expectEqual(result.card(.proxyTun)?.severity, .ok)
                t.expectEqual(result.card(.proxyTun)?.conclusion, "配置关闭")
                t.expectEqual(result.card(.proxyDNS)?.severity, .ok)
                let dns = try t.require(result.card(.primaryDNS))
                t.expectEqual(dns.severity, .warning)
                t.expectEqual(dns.faultKey, .dnsResidual)
                t.expectEqual(dns.hint, "可能是残留配置")
                // TUN 关闭且 DNS 已不含 114 → 正常。
                let cleaned = F.evaluate(F.withSavedDNS(snapshot, []))
                t.expectEqual(cleaned.severity, .ok)
                t.expectEqual(cleaned.card(.primaryDNS)?.conclusion, "TUN 已关闭，DNS 未手动设置")
            },
            TestCase("表7 黄：TUN 配置开启，但隧道接口不存在") { t in
                let snapshot = F.withoutInterface(try F.snapshot(.a), "utun1024")
                let result = F.evaluate(snapshot)
                let tun = try t.require(result.card(.proxyTun))
                t.expectEqual(result.tunState, .inactive)
                t.expectEqual(tun.severity, .warning)
                t.expectEqual(tun.conclusion, "配置开启，但 TUN 未生效")
                t.expectEqual(tun.faultKey, .tunInactive)
                t.expect(tun.evidence.contains("未找到 IPv4 位于 198.18.0.0/16 的 UP utun"), "\(tun.evidence)")
                t.expectEqual(result.severity, .warning)
                t.expectEqual(result.faultKeys, [.tunInactive])
            },
            TestCase("表7 黄：TUN 配置开启，但 verge-mihomo 未运行") { t in
                var snapshot = try F.snapshot(.a)
                snapshot.mihomoRunning = .collected(false)
                let result = F.evaluate(snapshot)
                t.expectEqual(result.tunState, .inactive)
                t.expect(result.card(.proxyTun)!.evidence.contains("verge-mihomo 未运行"))
                t.expectEqual(result.faultKeys, [.tunInactive])
                // DNS 仍与预期一致，不另报。
                t.expectEqual(result.card(.primaryDNS)?.severity, .ok)
            },
            TestCase("表8 黄：TUN 运行，但 Mihomo DNS 无响应") { t in
                var snapshot = try F.snapshot(.a)
                snapshot.mihomoDNS = .noResponse(port: 7874)
                let result = F.evaluate(snapshot)
                let card = try t.require(result.card(.proxyDNS))
                t.expectEqual(card.severity, .warning)
                t.expectEqual(card.conclusion, "7874 端口无响应")
                t.expectEqual(result.faultKeys, [.mihomoNoResponse])
            },
            TestCase("表9 灰：VPN 状态未确认，不评估 DNS 规则、不给修复建议") { t in
                // C 组的 DNS 本应判红，但 VPN 进程存在而无隧道 → 未确认。
                let snapshot = F.addingProcess(try F.snapshot(.c), F.vpnProcess)
                let result = F.evaluate(snapshot)
                t.expectEqual(result.vpnState, .unconfirmed)
                t.expectEqual(result.severity, .unknown)
                t.expectEqual(result.faultKeys, [])
                let dns = try t.require(result.card(.primaryDNS))
                t.expectEqual(dns.severity, .unknown)
                t.expectNil(dns.hint)
                t.expectEqual(result.card(.vpn)?.conclusion, "状态未确认")
                t.expect(result.card(.vpn)!.evidence.contains("VPN 进程存在，但未发现隧道和隧道路由"))
            },
            TestCase("表10 灰：Clash Verge 配置缺失或不可读，显示具体原因") { t in
                var snapshot = try F.snapshot(.a)
                snapshot.clashConfig = .failed(reason: "clash-verge.yaml 不存在")
                let result = F.evaluate(snapshot)
                let tun = try t.require(result.card(.proxyTun))
                t.expectEqual(tun.severity, .unknown)
                t.expectEqual(tun.conclusion, "证据不足：Clash Verge 配置缺失或不可读")
                t.expectEqual(tun.evidence, ["原因：clash-verge.yaml 不存在"])
                t.expectEqual(result.severity, .unknown)
                t.expectEqual(result.faultKeys, [])
                // C 组配置不可读时也不误报红。
                var c = try F.snapshot(.c)
                c.clashConfig = .failed(reason: "权限不足")
                let cResult = F.evaluate(c)
                t.expectEqual(cResult.severity, .unknown)
                t.expectEqual(cResult.faultKeys, [])
            },
            TestCase("表10 灰：配置缺少 fake-ip-range 或 TUN 开关") { t in
                var snapshot = try F.snapshot(.a)
                snapshot.clashConfig = .collected(ClashConfig(vergeTunModeEnabled: true, tunEnabled: true, dnsListenPort: 7874))
                let result = F.evaluate(snapshot)
                t.expectEqual(result.tunState, .unknown)
                t.expectEqual(result.card(.proxyTun)?.severity, .unknown)
                snapshot.clashConfig = .collected(ClashConfig())
                t.expectEqual(F.evaluate(snapshot).card(.proxyTun)?.conclusion, "证据不足：配置中未找到 TUN 开关")
            },
            TestCase("表11：VPN 断开时不探测 VPN 站点，显示“未连接 VPN”") { t in
                let result = F.evaluate(try F.snapshot(.a))
                t.expect(!result.intranetProbeEnabled)
                let decision = SiteCatalog.intranetDecision(intranetURL: URL(string: "https://intranet.example.test/")!,
                                                            vpnState: result.vpnState)
                t.expectEqual(decision, .vpnDisconnected)
                t.expectEqual(decision.skippedText, "未连接 VPN")
            },

            // MARK: 证据冲突

            TestCase("冲突：状态文件显示已连接，但无进程和隧道") { t in
                var snapshot = try F.snapshot(.a)
                snapshot.vpnStatusFiles["example"] = .present(VPNStatus(status: true, connecting: false,
                                                               tunnelIP: "10.9.0.2", dnsServers: ["10.9.0.53"]))
                let result = F.evaluate(snapshot)
                t.expectEqual(result.vpnState, .unconfirmed)
                t.expect(result.card(.vpn)!.evidence.contains("状态文件显示已连接，与进程和隧道证据矛盾"))
                t.expectEqual(result.card(.primaryDNS)?.severity, .unknown)
            },
            TestCase("冲突：进程和隧道都在，但状态文件显示已断开") { t in
                var snapshot = try F.snapshot(.b)
                snapshot.vpnStatusFiles["example"] = .present(VPNStatus(status: false, connecting: false,
                                                               tunnelIP: "10.9.0.2", dnsServers: ["10.9.0.53"]))
                let result = F.evaluate(snapshot)
                t.expectEqual(result.vpnState, .unconfirmed)
                t.expectEqual(result.severity, .unknown)
            },
            TestCase("冲突：隧道存在但没有 OpenVPN 进程") { t in
                let result = F.evaluate(F.withoutVPNProcess(try F.snapshot(.b)))
                t.expectEqual(result.vpnState, .unconfirmed)
                t.expect(result.card(.vpn)!.evidence.contains("未发现 VPN 进程，但存在隧道或隧道路由"))
                t.expectEqual(result.faultKeys, [])
            },
            TestCase("未采集进程列表 → 未确认") { t in
                var snapshot = try F.snapshot(.c)
                snapshot.processes = .notCollected
                let result = F.evaluate(snapshot)
                t.expectEqual(result.vpnState, .unconfirmed)
                t.expectEqual(result.faultKeys, [])
            },

            // MARK: 宽限期

            TestCase("宽限期：显示切换中，不判故障") { t in
                let result = F.evaluate(try F.snapshot(.c), inGracePeriod: true)
                t.expect(result.isInGracePeriod)
                t.expectEqual(result.vpnState, .switching)
                t.expectEqual(result.severity, .unknown)
                t.expectEqual(result.faultKeys, [])
                t.expectEqual(result.primaryReason, "网络切换中")
                t.expectEqual(result.card(.vpn)?.conclusion, "切换中")
                t.expectEqual(result.card(.primaryDNS)?.conclusion, "切换中，暂不评估")
                t.expect(!result.intranetProbeEnabled)
            },
            TestCase("宽限期：TUN 未生效降为灰") { t in
                let snapshot = F.withoutInterface(try F.snapshot(.a), "utun1024")
                let result = F.evaluate(snapshot, inGracePeriod: true)
                let tun = try t.require(result.card(.proxyTun))
                t.expectEqual(tun.severity, .unknown)
                t.expectNil(tun.faultKey)
                t.expect(tun.conclusion.hasPrefix("切换中："), tun.conclusion)
                t.expectEqual(result.faults, [])
            },

            // MARK: 有线、Tailscale、进程匹配

            TestCase("主网络为有线：DNS 检查跟随主服务") { t in
                let wiredA = F.withService(try F.snapshot(.a), name: "USB 10/100/1000 LAN", interface: "en7")
                let a = F.evaluate(wiredA)
                t.expectEqual(a.severity, .ok)
                t.expectEqual(a.card(.primaryDNS)?.title, "USB 10/100/1000 LAN DNS")
                t.expectEqual(a.primaryServiceName, "USB 10/100/1000 LAN")

                let wiredC = F.withService(try F.snapshot(.c), name: "Ethernet", interface: "en7")
                let c = F.evaluate(wiredC)
                t.expectEqual(c.severity, .critical)
                t.expectEqual(c.card(.primaryDNS)?.label, "主网络 DNS（Ethernet）")
                t.expectEqual(c.faultKeys, [.dnsNotRestored])
            },
            TestCase("Tailscale 不干扰判定") { t in
                // Tailscale 隧道带大量路由、解析器含 VPN DNS，且状态文件不存在，也不能被当成 VPN。
                var snapshot = try F.snapshot(.a)
                var routes = snapshot.routes.value ?? []
                for index in 0..<20 {
                    routes.append(RouteEntry(destination: "100.\(64 + index).1/24", gateway: "link#22",
                                             flags: "UCS", interfaceName: "utun3"))
                }
                snapshot.routes = .collected(routes)
                var resolvers = snapshot.resolvers.value ?? []
                resolvers.append(Resolver(isScoped: false, number: 9, domain: "corp.example",
                                          nameservers: ["10.9.0.53", "10.9.0.54"]))
                snapshot.resolvers = .collected(resolvers)
                let result = F.evaluate(snapshot)
                t.expectEqual(result.vpnState, .disconnected)
                t.expectEqual(result.severity, .ok)
                t.expect(result.diagnosticNotes.contains { $0.contains("utun3") && $0.contains("Tailscale") },
                         "\(result.diagnosticNotes)")
                // B 组（连接期）同样不受影响。
                t.expectEqual(F.evaluate(try F.snapshot(.b)).vpnState, .connected)
            },
            TestCase("命令行含 VPN 可执行文件名的其他进程不算 VPN") { t in
                let support = F.vpnExecutables[0]
                let impostors = [
                    ProcessEntry(pid: 13543, executablePath: "/usr/bin/grep", commandLine: "grep example-tunnel"),
                    ProcessEntry(pid: 13544, executablePath: "/bin/sh", commandLine: "sh -c ps aux | grep \(support)"),
                    ProcessEntry(pid: 13545, executablePath: "/private/tmp/example-tunnel"),
                    ProcessEntry(pid: 13546, executablePath: support + ".bak"),
                    ProcessEntry(pid: 13547, executablePath: nil, commandLine: support),
                ]
                var snapshot = try F.snapshot(.a)
                for entry in impostors { snapshot = F.addingProcess(snapshot, entry) }
                let result = F.evaluate(snapshot)
                t.expectEqual(result.vpnState, .disconnected)
                t.expectEqual(result.severity, .ok)
            },
            TestCase("配置中的第二个可执行文件路径同样识别") { t in
                var snapshot = F.withoutVPNProcess(try F.snapshot(.b))
                snapshot = F.addingProcess(snapshot, ProcessEntry(pid: 8000, executablePath: FixtureLoader.vpnExecutables[1]))
                t.expectEqual(F.evaluate(snapshot).vpnState, .connected)
            },

            // MARK: 状态文件不可读时的回退

            TestCase("状态文件不可读：按路由数量识别隧道") { t in
                var snapshot = try F.snapshot(.b)
                snapshot.vpnStatusFiles["example"] = .unreadable(reason: "权限不足")
                let result = F.evaluate(snapshot)
                t.expectEqual(result.vpnState, .connected)
                t.expect(result.card(.vpn)!.evidence.contains { $0.contains("按路由数量识别") },
                         "\(result.card(.vpn)!.evidence)")
                // 无法取得 VPN DNS → DNS 卡为灰。
                t.expectEqual(result.card(.primaryDNS)?.severity, .unknown)
                t.expectEqual(result.card(.primaryDNS)?.conclusion, "无法确认 VPN 下发的 DNS（状态文件不可读）")
            },
            TestCase("回退识别排除 fake-ip 网段（配置不可读时也排除 198.18/15）") { t in
                var snapshot = try F.snapshot(.a)
                snapshot.clashConfig = .failed(reason: "不可读")
                let result = F.evaluate(snapshot)
                // utun1024 有 11 条路由，但位于 fake-ip 网段，不能当成 VPN 隧道。
                t.expectEqual(result.vpnState, .disconnected)
            },
            TestCase("配置中的隧道网段用于识别") { t in
                var snapshot = try F.snapshot(.b)
                snapshot.vpnStatusFiles["example"] = .missing
                snapshot.routes = .collected([])
                var adapter = F.vpnAdapter
                adapter.tunnel = VPNAdapterConfig.Tunnel(cidr: "10.9.0.0/16")
                let result = LocalEvaluator(paths: F.paths, adapters: [adapter])
                    .evaluate(snapshot: snapshot, settings: AppSettings(), inGracePeriod: false)
                t.expectEqual(result.vpnState, .connected)
                t.expect(result.card(.vpn)!.evidence.contains { $0.contains("按配置的隧道网段识别") })
            },

            // MARK: 其他

            TestCase("预期 DNS 比较忽略顺序，支持多个") { t in
                let settings = AppSettings(expectedDNS: ["223.5.5.5", "119.29.29.29"])
                let snapshot = F.withSavedDNS(try F.snapshot(.a), ["119.29.29.29", "223.5.5.5"])
                t.expectEqual(F.evaluate(snapshot, settings: settings).severity, .ok)
                // 只含其中一个 → 与预期不一致。
                let partial = F.evaluate(try F.snapshot(.a), settings: settings)
                t.expectEqual(partial.severity, .critical)
                t.expectEqual(partial.card(.primaryDNS)?.conclusion, "VPN 已断开、TUN 运行中，DNS 未恢复为 223.5.5.5、119.29.29.29")
            },
            TestCase("实际 TUN 接口名与配置不同：按网段识别，设备名只作提示") { t in
                var snapshot = F.withoutInterface(try F.snapshot(.a), "utun1024")
                var interfaces = snapshot.interfaces.value ?? []
                interfaces.append(InterfaceInfo(name: "utun12", isUp: true, ipv4Addresses: [IPv4("198.18.0.1")!]))
                snapshot.interfaces = .collected(interfaces)
                let result = F.evaluate(snapshot)
                t.expectEqual(result.tunState, .running(interface: "utun12"))
                t.expect(result.card(.proxyTun)!.evidence.contains("配置设备名为 utun1024，实际接口为 utun12（设备名只作提示）"))
            },
            TestCase("保存值 [\"\"] 在任何入口都视为空") { t in
                var snapshot = try F.snapshot(.a)
                var service = try t.require(snapshot.primaryService.value)
                service.savedDNS = [""]
                snapshot.primaryService = .collected(service)
                let result = F.evaluate(snapshot)
                t.expectEqual(result.faultKeys, [.dnsNotRestored])
                t.expect(result.card(.primaryDNS)!.evidence.contains("保存值：空（DNS 已被清空）"))
            },
            TestCase("主服务读取失败 → DNS 卡为灰") { t in
                var snapshot = try F.snapshot(.c)
                snapshot.primaryService = .failed(reason: "SCDynamicStore 无响应")
                let result = F.evaluate(snapshot)
                t.expectEqual(result.card(.primaryDNS)?.severity, .unknown)
                t.expectEqual(result.card(.primaryDNS)?.conclusion, "证据不足：未能读取主网络服务（SCDynamicStore 无响应）")
                t.expectEqual(result.faultKeys, [])
            },
            TestCase("原因排序：红在前，同级按 DNS、TUN、Mihomo、VPN") { t in
                var snapshot = F.withoutInterface(try F.snapshot(.a), "utun1024")
                snapshot.mihomoDNS = .noResponse(port: 7874)
                snapshot = F.withSavedDNS(snapshot, ["8.8.8.8"])
                let result = F.evaluate(snapshot)
                // TUN 未生效 → DNS 规则不评估（灰）；Mihomo 无响应在 TUN 未生效时为灰。
                t.expectEqual(result.reasons.map(\.severity), [.warning, .unknown, .unknown])
                t.expectEqual(result.reasons.first?.faultKey, .tunInactive)
            },
        ])
    }
}
