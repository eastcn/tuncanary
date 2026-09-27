import Foundation
import TunCanaryCore

enum BasicsTests {
    static var suite: TestSuite {
        TestSuite("Core.Basics", [
            TestCase("Severity 排序为红 > 黄 > 灰 > 绿") { t in
                t.expect(Severity.critical > .warning)
                t.expect(Severity.warning > .unknown)
                t.expect(Severity.unknown > .ok)
                t.expectEqual(Severity.worst([.ok, .unknown, .warning]), .warning)
                t.expectEqual(Severity.worst([.unknown, .ok]), .unknown)
                t.expectEqual(Severity.worst([]), .ok)
                t.expectEqual([Severity.critical, .ok, .warning, .unknown].sorted(), [.ok, .unknown, .warning, .critical])
            },
            TestCase("Severity 符号与中文名") { t in
                t.expectEqual(Severity.allCases.map(\.symbol), ["✓", "?", "!", "✕"])
                t.expectEqual(Severity.allCases.map(\.displayName), ["正常", "未确认", "需关注", "故障"])
                t.expect(!Severity.ok.isAlerting)
                t.expect(!Severity.unknown.isAlerting)
                t.expect(Severity.warning.isAlerting)
                t.expect(Severity.critical.isAlerting)
            },
            TestCase("AppIdentity 固定 bundle id 与名称") { t in
                t.expectEqual(AppIdentity.bundleID, "io.github.eastcn.tuncanary")
                t.expectEqual(AppIdentity.name, "TunCanary")
            },
            TestCase("KnownPaths 以 home 目录计算") { t in
                let paths = KnownPaths(homeDirectory: "/Users/someone/")
                t.expectEqual(paths.homeDirectory, "/Users/someone")
                t.expectEqual(paths.clashVergeConfigDirectory,
                              "/Users/someone/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev")
                t.expectEqual(paths.vergeConfigFile, paths.clashVergeConfigDirectory + "/verge.yaml")
                t.expectEqual(paths.clashVergeConfigFile, paths.clashVergeConfigDirectory + "/clash-verge.yaml")
                t.expectEqual(paths.vpnAdaptersDirectory, "/Users/someone/Library/Application Support/TunCanary/adapters")
                t.expectEqual(KnownPaths.expandTilde("~/a/b", home: "/Users/someone/"), "/Users/someone/a/b")
                t.expectEqual(KnownPaths.expandTilde("/opt/x", home: "/Users/someone"), "/opt/x")
                t.expectEqual(KnownPaths.expandTilde("~other/x", home: "/Users/someone"), "~other/x")
            },
            TestCase("DNSList 去掉空字符串，[\"\"] 视为空") { t in
                t.expectEqual(DNSList.normalize([""]), [])
                t.expectEqual(DNSList.normalize([" 10.0.0.1 ", "", "10.0.0.1", "10.0.0.2"]), ["10.0.0.1", "10.0.0.2"])
                t.expectEqual(DNSList.split("10.9.0.53, 10.9.0.54"), ["10.9.0.53", "10.9.0.54"])
                t.expectEqual(DNSList.split(" , ,"), [])
                t.expectEqual(DNSList.split("1.1.1.1，8.8.8.8、9.9.9.9 4.4.4.4"), ["1.1.1.1", "8.8.8.8", "9.9.9.9", "4.4.4.4"])
                t.expect(DNSList.sameSet(["a", "b"], ["b", "a", ""]))
                t.expect(!DNSList.sameSet(["a"], ["a", "b"]))
                t.expectEqual(DNSList.display([""]), "空")
            },
            TestCase("LatencyFormat 取整毫秒") { t in
                t.expectEqual(LatencyFormat.milliseconds(0.008), "8 ms")
                t.expectEqual(LatencyFormat.milliseconds(0.1804), "180 ms")
                t.expectEqual(LatencyFormat.milliseconds(0.0355), "36 ms")
            },
        ])
    }
}

enum IPv4Tests {
    static var suite: TestSuite {
        TestSuite("Core.IPv4", [
            TestCase("解析点分十进制") { t in
                t.expectEqual(IPv4("192.168.0.1")?.octets, [192, 168, 0, 1])
                t.expectEqual(IPv4("119.29.29.29")?.description, "119.29.29.29")
                t.expectEqual(IPv4(" 10.0.0.1 ")?.description, "10.0.0.1")
                for bad in ["", "1.2.3", "1.2.3.4.5", "256.0.0.1", "a.b.c.d", "1..2.3", "1.2.3.-4", "fe80::1"] {
                    t.expectNil(IPv4(bad), bad)
                }
                t.expect(IPv4("10.0.0.1")! < IPv4("10.0.0.2")!)
            },
            TestCase("CIDR 允许主机位非零") { t in
                let range = try t.require(IPv4CIDR("198.18.0.1/16"))
                t.expectEqual(range.address.description, "198.18.0.1")
                t.expectEqual(range.networkAddress.description, "198.18.0.0")
                t.expectEqual(range.normalized.description, "198.18.0.0/16")
                t.expect(range.contains(IPv4("198.18.0.26")!))
                t.expect(range.contains(IPv4("198.18.255.255")!))
                t.expect(!range.contains(IPv4("198.19.0.1")!))
                t.expect(!range.contains(IPv4("142.250.0.1")!))
            },
            TestCase("CIDR 严格格式") { t in
                for bad in ["10.0.0.0", "10.0.0.0/33", "10.0.0/8", "10.0.0.0/", "10.0.0.0/a", "abc", "10.0.0.0/8/1"] {
                    t.expectNil(IPv4CIDR(bad), bad)
                }
                t.expect(IPv4CIDR("0.0.0.0/0")!.contains(IPv4("8.8.8.8")!))
                t.expect(IPv4CIDR("10.0.0.1/32")!.contains(IPv4("10.0.0.1")!))
                t.expect(!IPv4CIDR("10.0.0.1/32")!.contains(IPv4("10.0.0.2")!))
            },
            TestCase("netstat 缩写目的地") { t in
                func check(_ raw: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
                    t.expectEqual(IPv4CIDR(netstatDestination: raw)?.normalized.description, expected, raw, file: file, line: line)
                }
                check("10.1/16", "10.1.0.0/16")
                check("10.77/16", "10.77.0.0/16")
                check("172.16", "172.16.0.0/16")
                check("128.0/1", "128.0.0.0/1")
                check("2/7", "2.0.0.0/7")
                check("127", "127.0.0.0/8")
                check("1", "1.0.0.0/8")
                check("192.168.0", "192.168.0.0/24")
                check("192.168.0.1", "192.168.0.1/32")
                check("10.78.9.9/32", "10.78.9.9/32")
                check("default", "0.0.0.0/0")
                t.expect(IPv4CIDR(netstatDestination: "128.0/1")!.contains(IPv4("203.0.113.9")!))
                t.expect(!IPv4CIDR(netstatDestination: "128.0/1")!.contains(IPv4("100.64.0.2")!))
                t.expectNil(IPv4CIDR(netstatDestination: "link#14"))
                t.expectNil(IPv4CIDR(netstatDestination: "xx:xx:xx:xx:xx:xx"))
                t.expectNil(IPv4CIDR(netstatDestination: "10.0/40"))
            },
            TestCase("IPv6：解析、压缩写法、全局单播与网段") { t in
                let ip = try t.require(IPv6("2001:0db8:0000:0000:0000:0000:0000:0001"))
                t.expectEqual(ip.description, "2001:db8::1")
                t.expect(ip.isGlobalUnicast)
                t.expect(!IPv6("fe80::1")!.isGlobalUnicast)
                t.expect(!IPv6("fdfe:dcba:9876::1")!.isGlobalUnicast)
                t.expect(!IPv6("::1")!.isGlobalUnicast)
                t.expect(IPv6("::ffff:198.18.0.10")!.isIPv4Mapped)
                t.expect(!IPv6("::ffff:198.18.0.10")!.isGlobalUnicast)
                t.expect(!IPv6("2001:db8::ffff:0:1")!.isIPv4Mapped)
                t.expect(!IPv6("::1")!.isIPv4Mapped)
                t.expectNil(IPv6("fe80::1%en0"))
                t.expectNil(IPv6("198.18.0.1"))
                t.expectNil(IPv6("2001:db8::/32"))
                t.expectNil(IPv6(bytes: [0, 1]))

                let range = try t.require(IPv6CIDR("fdfe:dcba:9876::1/64"))
                t.expect(range.contains(IPv6("fdfe:dcba:9876::abcd")!))
                t.expect(!range.contains(IPv6("fdfe:dcba:9877::1")!))
                let odd = try t.require(IPv6CIDR("2001:db8::/33"))
                t.expect(odd.contains(IPv6("2001:db8:7fff::1")!))
                t.expect(!odd.contains(IPv6("2001:db8:8000::1")!))
                t.expect(IPv6CIDR("::/0")!.contains(IPv6("2001:db8::1")!))
                t.expectNil(IPv6CIDR("2001:db8::/129"))
                t.expectNil(IPv6CIDR("2001:db8::"))
                t.expectNil(IPv6CIDR("198.18.0.1/16"))
            },
            TestCase("Tailscale 网段与脱敏判定") { t in
                t.expect(IPv4CIDR.tailscale.contains(IPv4("100.64.0.2")!))
                t.expect(IPv4CIDR.tailscale.contains(IPv4("100.127.255.254")!))
                t.expect(IPv4CIDR.tailscale.contains(IPv4("100.100.100.100")!))
                t.expect(!IPv4CIDR.tailscale.contains(IPv4("100.128.0.1")!))
                t.expect(IPv4("10.1.2.3")!.isPrivateForRedaction)
                t.expect(IPv4("172.20.0.1")!.isPrivateForRedaction)
                t.expect(IPv4("192.168.0.1")!.isPrivateForRedaction)
                t.expect(!IPv4("172.32.0.1")!.isPrivateForRedaction)
                t.expect(!IPv4("119.29.29.29")!.isPrivateForRedaction)
                t.expect(!IPv4("198.18.0.1")!.isPrivateForRedaction)
            },
        ])
    }
}
