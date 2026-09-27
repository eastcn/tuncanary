import Foundation
import TunCanaryCore

/// 三组合成快照：A 绿、B 绿（连接期）、C 红。
enum FixtureTests {
    static var suite: TestSuite {
        TestSuite("Core.Fixtures", [
            TestCase("fixture 目录可由 #filePath 定位") { t in
                for scenario in FixtureLoader.Scenario.allCases {
                    let path = FixtureLoader.directory(scenario).appendingPathComponent("ifconfig.txt").path
                    t.expect(FileManager.default.fileExists(atPath: path), path)
                }
            },
            TestCase("ps 解析：展开 ~，路径含空格") { t in
                let processes = FixtureLoader.parsePS(try FixtureLoader.text(.b, "ps.txt"), home: "/Users/tester")
                t.expectEqual(processes.count, 7)
                let tunnel = try t.require(processes.first { $0.pid == 7300 })
                t.expectEqual(tunnel.executablePath, FixtureLoader.vpnExecutables[0])
                let helper = try t.require(processes.first { $0.pid == 3102 })
                t.expectEqual(helper.executablePath,
                              "/Applications/Example VPN.app/Contents/Frameworks/Example VPN Helper.app/Contents/MacOS/Example VPN Helper")
                let agent = try t.require(processes.first { $0.pid == 3105 })
                t.expectEqual(agent.executablePath, "/Users/tester/Library/Application Support/Example VPN/agent/example-agent")
                t.expect(processes.contains { $0.executableName == "verge-mihomo" })
            },
            TestCase("A 组：VPN 断开、TUN 运行、DNS 114 → 绿") { t in
                let snapshot = try FixtureLoader.snapshot(.a)
                t.expectEqual(snapshot.vpnStatusFiles["example"], .missing)
                let result = FixtureLoader.evaluate(snapshot)
                t.expectEqual(result.severity, .ok)
                t.expectEqual(result.vpnState, .disconnected)
                t.expectEqual(result.tunState, .running(interface: "utun1024"))
                t.expectEqual(result.faultKeys, [])
                t.expect(!result.intranetProbeEnabled)
                t.expectEqual(result.primaryReason, "各项检查正常")
                t.expectEqual(result.cards.map(\.kind), StatusCardKind.displayOrder)
                // 合成数据带一个 Tailscale 隧道，所以有第 5 张 Tailnet 卡。
                t.expectEqual(result.cards.map(\.severity), [.ok, .ok, .ok, .ok, .ok])
                t.expectEqual(result.tailnetDecision, .notConfigured)
                let dns = try t.require(result.card(.primaryDNS))
                t.expectEqual(dns.title, "Wi-Fi DNS")
                t.expectEqual(dns.conclusion, "DNS 为 119.29.29.29，符合预期")
                t.expect(dns.evidence.contains("系统解析 www.google.com 返回 fake-ip 198.18.0.26"), "\(dns.evidence)")
                t.expectEqual(result.card(.proxyTun)?.conclusion, "配置开启，utun1024 存在")
                t.expectEqual(result.card(.proxyDNS)?.conclusion, "7874 端口响应 8 ms")
                t.expectEqual(result.card(.vpn)?.conclusion, "已断开")
            },
            TestCase("B 组：VPN 已连接、DNS 为 VPN 下发的 DNS → 绿（连接期）") { t in
                let result = FixtureLoader.evaluate(try FixtureLoader.snapshot(.b))
                t.expectEqual(result.severity, .ok)
                t.expectEqual(result.vpnState, .connected)
                t.expect(result.intranetProbeEnabled)
                t.expectEqual(result.faultKeys, [])
                let dns = try t.require(result.card(.primaryDNS))
                t.expectEqual(dns.severity, .ok)
                t.expectEqual(dns.conclusion, "DNS 为 VPN 下发的 DNS（连接期状态）")
                t.expectEqual(dns.hint, "连接期状态；启用内网站点探测")
                let vpn = try t.require(result.card(.vpn))
                t.expectEqual(vpn.title, "Example VPN")
                t.expectEqual(vpn.conclusion, "已连接")
                t.expect(vpn.evidence.contains("VPN 进程运行中（pid 7300）"), "\(vpn.evidence)")
                t.expect(vpn.evidence.contains("隧道路由 12 条"), "\(vpn.evidence)")
                t.expect(vpn.evidence.contains { $0.hasPrefix("隧道 utun7 已启用") }, "\(vpn.evidence)")
                t.expectEqual(SiteCatalog.intranetDecision(intranetURL: URL(string: "https://intranet.example.test/"),
                                                           vpnState: result.vpnState).site?.id, "intranet")
            },
            TestCase("C 组：VPN 刚断开、DNS 被清空 → 红 dns.notRestored") { t in
                let result = FixtureLoader.evaluate(try FixtureLoader.snapshot(.c))
                t.expectEqual(result.severity, .critical)
                t.expectEqual(result.vpnState, .disconnected)
                t.expectEqual(result.faultKeys, [.dnsNotRestored])
                let dns = try t.require(result.card(.primaryDNS))
                t.expectEqual(dns.severity, .critical)
                t.expectEqual(dns.label, "主网络 DNS（Wi-Fi）")
                t.expectEqual(dns.conclusion, "VPN 已断开、TUN 运行中，DNS 未恢复为 119.29.29.29")
                t.expectEqual(dns.hint, "等待 VPN 完全断开后，关闭并重新开启 Clash TUN")
                t.expect(dns.evidence.contains("保存值：空（DNS 已被清空）"), "\(dns.evidence)")
                t.expect(dns.evidence.contains("生效 DNS：192.168.1.1"), "\(dns.evidence)")
                t.expect(dns.evidence.contains("系统解析 www.google.com 返回真实地址 142.250.0.1"), "\(dns.evidence)")
                t.expectEqual(result.primaryReason, "主网络 DNS（Wi-Fi）：VPN 已断开、TUN 运行中，DNS 未恢复为 119.29.29.29")
                t.expectEqual(result.faults.first?.hint, "等待 VPN 完全断开后，关闭并重新开启 Clash TUN")
                // 其余三张卡正常。
                t.expectEqual(result.card(.proxyTun)?.severity, .ok)
                t.expectEqual(result.card(.vpn)?.severity, .ok)
                t.expectEqual(result.card(.proxyDNS)?.severity, .ok)
            },
            TestCase("C 组 + 命令行含 VPN 可执行文件路径的 grep 进程 → 仍为红") { t in
                // 临时进程的命令行可能带有 VPN 可执行文件路径，但可执行文件本身是 grep。
                let grep = ProcessEntry(
                    pid: 12861, executablePath: "/usr/bin/grep",
                    commandLine: "grep -c \(FixtureLoader.vpnExecutables[0])")
                let snapshot = FixtureLoader.addingProcess(try FixtureLoader.snapshot(.c), grep)
                let result = FixtureLoader.evaluate(snapshot)
                t.expectEqual(result.vpnState, .disconnected)
                t.expectEqual(result.severity, .critical)
                t.expectEqual(result.faultKeys, [.dnsNotRestored])
            },
        ])
    }
}
