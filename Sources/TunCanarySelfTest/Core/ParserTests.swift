import Foundation
import TunCanaryCore

enum ClashConfigParserTests {
    static var suite: TestSuite {
        TestSuite("Core.ClashConfigParser", [
            TestCase("提取六个字段") { t in
                let config = FixtureLoader.clashConfig()
                t.expectEqual(config.vergeTunModeEnabled, true)
                t.expectEqual(config.tunEnabled, true)
                t.expectEqual(config.tunDevice, "utun1024")
                t.expectEqual(config.dnsListenPort, 7874)
                t.expectEqual(config.dnsEnhancedMode, "fake-ip")
                t.expectEqual(config.fakeIPRange?.description, "198.18.0.1/16")
                t.expect(config.isFakeIPMode)
                t.expectEqual(config.tunConfigured, true)
            },
            TestCase("不保存 secret 等其他字段") { t in
                let yaml = FixtureLoader.clashVergeYAML()
                let scanned = ClashConfigParser.scan(yaml, wanted: ["tun.enable", "dns.listen"])
                t.expectEqual(Set(scanned.keys), ["tun.enable", "dns.listen"])
                let config = FixtureLoader.clashConfig()
                let dump = String(reflecting: config)
                t.expectNotContains(dump, "synthetic-secret")
                t.expectNotContains(dump, "synthetic-password")
                t.expectNotContains(dump, "203.0.113.9")
                // 模型只有六个配置字段、fake-ip 过滤名单与模式，外加手动模式的两个标记。
                t.expectEqual(Mirror(reflecting: config).children.count, 10)
                t.expect(!config.isManual)
                t.expectNil(config.coreProcessName)
            },
            TestCase("引号与行尾注释") { t in
                let yaml = """
                tun:
                  enable: "true"   # 注释
                  device: 'utun7'
                dns:
                  listen: '0.0.0.0:7874' # 监听
                  enhanced-mode: "fake-ip"
                  fake-ip-range: 198.18.0.1/16 # 网段
                """
                let config = ClashConfigParser.parse(vergeYAML: nil, clashVergeYAML: yaml)
                t.expectEqual(config.tunEnabled, true)
                t.expectEqual(config.tunDevice, "utun7")
                t.expectEqual(config.dnsListenPort, 7874)
                t.expectEqual(config.dnsEnhancedMode, "fake-ip")
                t.expectEqual(config.fakeIPRange?.description, "198.18.0.1/16")
            },
            TestCase("只读一层子键，忽略更深缩进和其他顶层键下的同名键") { t in
                let yaml = """
                profile:
                  enable: false
                tun:
                  auto-route: true
                  nested:
                    enable: false
                    device: wrong
                  enable: true
                  device: utun1024
                dns:
                  nameserver-policy:
                    'geosite:cn': 119.29.29.29
                  fallback:
                  - listen: 1.1.1.1:53
                  listen: 127.0.0.1:1053
                """
                let config = ClashConfigParser.parse(vergeYAML: nil, clashVergeYAML: yaml)
                t.expectEqual(config.tunEnabled, true)
                t.expectEqual(config.tunDevice, "utun1024")
                t.expectEqual(config.dnsListenPort, 1053)
            },
            TestCase("顶层列表项不打断后续键") { t in
                let yaml = """
                proxies:
                - name: a
                  type: ss
                - name: b
                dns:
                  listen: :7874
                  enhanced-mode: fake-ip
                """
                let config = ClashConfigParser.parse(vergeYAML: nil, clashVergeYAML: yaml)
                t.expectEqual(config.dnsListenPort, 7874)
                t.expectEqual(config.dnsEnhancedMode, "fake-ip")
            },
            TestCase("TUN 开关组合") { t in
                t.expectEqual(FixtureLoader.clashConfig(tunOn: false).tunConfigured, false)
                let vergeOff = ClashConfigParser.parse(vergeYAML: "enable_tun_mode: false",
                                                       clashVergeYAML: "tun:\n  enable: true")
                t.expectEqual(vergeOff.tunConfigured, false)
                let onlyClash = ClashConfigParser.parse(vergeYAML: nil, clashVergeYAML: "tun:\n  enable: true")
                t.expectEqual(onlyClash.tunConfigured, true)
                let none = ClashConfigParser.parse(vergeYAML: "", clashVergeYAML: "mixed-port: 7897")
                t.expectNil(none.tunConfigured)
            },
            TestCase("空文本与非法值") { t in
                let empty = ClashConfigParser.parse(vergeYAML: "", clashVergeYAML: "")
                t.expectEqual(empty, ClashConfig())
                let bad = ClashConfigParser.parse(vergeYAML: "enable_tun_mode: maybe", clashVergeYAML: """
                dns:
                  listen: 0.0.0.0:abc
                  fake-ip-range: 198.18.0.1
                """)
                t.expectNil(bad.vergeTunModeEnabled)
                t.expectNil(bad.dnsListenPort)
                t.expectNil(bad.fakeIPRange)
            },
            TestCase("端口写法与 CRLF") { t in
                t.expectEqual(ClashConfigParser.parsePort("[::]:1053"), 1053)
                t.expectEqual(ClashConfigParser.parsePort("7874"), 7874)
                t.expectNil(ClashConfigParser.parsePort("0.0.0.0:70000"))
                let crlf = "tun:\r\n  enable: true\r\n  device: utun1024\r\n"
                let config = ClashConfigParser.parse(vergeYAML: nil, clashVergeYAML: crlf)
                t.expectEqual(config.tunEnabled, true)
                t.expectEqual(config.tunDevice, "utun1024")
            },
        ])
    }
}

enum VPNStatusFileParserTests {
    static let fields = VPNAdapterConfig.StatusFile(
        path: "~/state.json", connected: "/session/active", connecting: "/session/pending",
        tunnelIP: "/session/address", dns: "/session/resolvers")

    static var suite: TestSuite {
        TestSuite("Core.VPNStatusFileParser", [
            TestCase("按 JSON Pointer 读取四个字段") { t in
                let json = #"{"session":{"active":true,"pending":false,"address":"10.9.0.2","resolvers":["10.9.0.53","10.9.0.54"]}}"#
                let status = try VPNStatusFileParser.parse(json, fields: fields)
                t.expectEqual(status.status, true)
                t.expectEqual(status.connecting, false)
                t.expectEqual(status.tunnelIP, "10.9.0.2")
                t.expectEqual(status.tunnelIPv4?.description, "10.9.0.2")
                t.expectEqual(status.dnsServers, ["10.9.0.53", "10.9.0.54"])
            },
            TestCase("其余字段不进入模型") { t in
                let json = """
                {"config": {"password": "synthetic-pass", "proxy": "203.0.113.5"},
                 "session": {"active": true, "address": "10.1.2.3", "resolvers": "10.0.0.53",
                             "user": "someone", "token": "synthetic-token"}}
                """
                let status = try VPNStatusFileParser.parse(json, fields: fields)
                let dump = String(reflecting: status)
                t.expectNotContains(dump, "synthetic")
                t.expectNotContains(dump, "someone")
                t.expectNotContains(dump, "203.0.113.5")
                t.expectEqual(Mirror(reflecting: status).children.count, 4)
            },
            TestCase("DNS 可为逗号分隔的字符串，去掉空白") { t in
                let status = try VPNStatusFileParser.parse(#"{"session":{"resolvers":" 10.0.0.1 , ,10.0.0.2 ,"}}"#, fields: fields)
                t.expectEqual(status.dnsServers, ["10.0.0.1", "10.0.0.2"])
                let empty = try VPNStatusFileParser.parse(#"{"session":{"resolvers":""}}"#, fields: fields)
                t.expectEqual(empty.dnsServers, [])
            },
            TestCase("缺字段为 nil，数字与字符串布尔兼容") { t in
                let status = try VPNStatusFileParser.parse(#"{"session":{"active":1}}"#, fields: fields)
                t.expectEqual(status.status, true)
                t.expectNil(status.connecting)
                t.expectNil(status.tunnelIP)
                t.expectEqual(status.dnsServers, [])
                t.expectEqual(try VPNStatusFileParser.parse(#"{"session":{"active":"false"}}"#, fields: fields).status, false)
                let blankIP = try VPNStatusFileParser.parse(#"{"session":{"address":"  "}}"#, fields: fields)
                t.expectNil(blankIP.tunnelIP)
            },
            TestCase("JSON Pointer 支持数组下标与转义") { t in
                let json = #"{"a/b":{"list":[{"on":true}]}}"#
                let pointer = VPNAdapterConfig.StatusFile(path: "/x", connected: "/a~1b/list/0/on")
                t.expectEqual(try VPNStatusFileParser.parse(json, fields: pointer).status, true)
                t.expectNil(JSONPointer("no-slash"))
                t.expectNil(JSONPointer("/list/01")?.resolve(in: ["list": [1, 2]]))
            },
            TestCase("非法 JSON 与没有任何配置字段时抛错") { t in
                t.expectThrows(try VPNStatusFileParser.parse("", fields: fields))
                t.expectThrows(try VPNStatusFileParser.parse("not json", fields: fields))
                do {
                    _ = try VPNStatusFileParser.parse(#"{"other": true}"#, fields: fields)
                    t.fail("应抛出 noConfiguredField")
                } catch let error as VPNStatusFileParseError {
                    t.expectEqual(error, .noConfiguredField)
                }
            },
            TestCase("VPN 配置解析 B、C 组状态文件（断开后保留旧值）") { t in
                let fields = try t.require(FixtureLoader.vpnAdapter.statusFile)
                let b = try VPNStatusFileParser.parse(try FixtureLoader.text(.b, "vpn-status.json"), fields: fields)
                t.expectEqual(b.status, true)
                t.expectEqual(b.connecting, false)
                t.expectEqual(b.tunnelIP, "10.9.0.2")
                t.expectEqual(b.dnsServers, ["10.9.0.53", "10.9.0.54"])
                let c = try VPNStatusFileParser.parse(try FixtureLoader.text(.c, "vpn-status.json"), fields: fields)
                t.expectEqual(c.status, false)
                t.expectEqual(c.tunnelIP, "10.9.0.2")
                t.expectEqual(c.dnsServers.count, 2)
            },
        ])
    }
}

enum ScutilDNSParserTests {
    static var suite: TestSuite {
        TestSuite("Core.ScutilDNSParser", [
            TestCase("A 组：普通段与 scoped 段") { t in
                let resolvers = ScutilDNSParser.parse(try FixtureLoader.text(.a, "scutil-dns.txt"))
                let normal = resolvers.filter { !$0.isScoped }
                let scoped = resolvers.filter(\.isScoped)
                t.expectEqual(normal.count, 8)
                t.expectEqual(scoped.count, 2)
                t.expectEqual(normal[0].nameservers, ["119.29.29.29"])
                t.expectNil(normal[0].domain)
                t.expectNil(normal[0].ifIndex)
                t.expectEqual(normal[1].domain, "local")
                t.expectEqual(normal[1].order, 300000)
                t.expectEqual(normal[7].domain, "example-tailnet.ts.net")
                t.expectEqual(normal[7].nameservers, ["100.100.100.100"])
                t.expectEqual(scoped[0].ifIndex, 15)
                t.expectEqual(scoped[0].interfaceName, "en0")
                t.expect(scoped[0].flags.contains("Scoped"))
                t.expectEqual(scoped[1].interfaceName, "utun3")
                t.expectEqual(scoped[1].nameservers, ["100.100.100.100"])
                t.expectEqual(scoped[1].number, 2)
            },
            TestCase("C 组：默认解析器带 if_index") { t in
                let resolvers = ScutilDNSParser.parse(try FixtureLoader.text(.c, "scutil-dns.txt"))
                let first = try t.require(resolvers.first)
                t.expect(!first.isScoped)
                t.expectEqual(first.nameservers, ["192.168.1.1"])
                t.expectEqual(first.ifIndex, 15)
                t.expectEqual(first.interfaceName, "en0")
            },
            TestCase("空输出与无关文本") { t in
                t.expectEqual(ScutilDNSParser.parse(""), [])
                t.expectEqual(ScutilDNSParser.parse("No DNS configuration available\n"), [])
            },
            TestCase("IPv6 与 search domain") { t in
                let text = """
                DNS configuration

                resolver #1
                  search domain[0] : corp.example
                  nameserver[0] : 10.0.0.53
                  nameserver[1] : fe80::1%en0
                  if_index : 7 (en7)
                """
                let resolver = try t.require(ScutilDNSParser.parse(text).first)
                t.expectEqual(resolver.searchDomains, ["corp.example"])
                t.expectEqual(resolver.nameservers, ["10.0.0.53", "fe80::1%en0"])
                t.expectEqual(resolver.interfaceName, "en7")
            },
        ])
    }
}

enum NetstatRouteParserTests {
    static var suite: TestSuite {
        TestSuite("Core.NetstatRouteParser", [
            TestCase("A 组：默认路由与 TUN 路由") { t in
                let routes = NetstatRouteParser.parse(try FixtureLoader.text(.a, "netstat-rn.txt"))
                t.expectEqual(routes.filter { $0.interfaceName == "utun1024" }.count, 11)
                let defaults = routes.filter(\.isDefault)
                t.expectEqual(defaults.count, 2)
                t.expectEqual(defaults.first?.gateway, "192.168.1.1")
                t.expectEqual(defaults.first?.interfaceName, "en0")
                let half = try t.require(routes.first { $0.destination == "128.0/1" })
                t.expectEqual(half.network?.normalized.description, "128.0.0.0/1")
                let tailscale = try t.require(routes.first { $0.destination == "100.64/10" })
                t.expectEqual(tailscale.interfaceName, "utun3")
                t.expectEqual(tailscale.network, IPv4CIDR.tailscale)
                // 带 Expire 列和 "!" 的行也要解析。
                t.expect(routes.contains { $0.destination == "169.254" && $0.interfaceName == "en0" })
            },
            TestCase("B 组：12 条 VPN 路由指向 utun7") { t in
                let routes = NetstatRouteParser.parse(try FixtureLoader.text(.b, "netstat-rn.txt"))
                let vpnRoutes = routes.filter { $0.interfaceName == "utun7" }
                t.expectEqual(vpnRoutes.count, 12)
                let route = try t.require(routes.first { $0.destination == "10.9/16" })
                t.expect(route.network?.contains(IPv4("10.9.0.53")!) == true)
                let short = try t.require(routes.first { $0.destination == "172.16" })
                t.expectEqual(short.network?.normalized.description, "172.16.0.0/16")
            },
            TestCase("空输出、只有表体、忽略 Internet6") { t in
                t.expectEqual(NetstatRouteParser.parse(""), [])
                let body = "default 192.168.0.1 UGScg en0\n10.8/16 10.8.0.1 UGSc utun3"
                t.expectEqual(NetstatRouteParser.parse(body).count, 2)
                let mixed = """
                Routing tables

                Internet:
                Destination        Gateway            Flags               Netif Expire
                default            192.168.0.1        UGScg                 en0

                Internet6:
                Destination        Gateway            Flags               Netif Expire
                default            fe80::1%en0        UGcg                  en0
                """
                let routes = NetstatRouteParser.parse(mixed)
                t.expectEqual(routes.count, 1)
                t.expectEqual(routes.first?.gateway, "192.168.0.1")
            },
        ])
    }
}

enum IfconfigParserTests {
    static var suite: TestSuite {
        TestSuite("Core.IfconfigParser", [
            TestCase("A 组接口") { t in
                let interfaces = IfconfigParser.parse(try FixtureLoader.text(.a, "ifconfig.txt"))
                t.expectEqual(interfaces.count, 8)
                let en0 = try t.require(interfaces.first { $0.name == "en0" })
                t.expect(en0.isUp)
                t.expect(!en0.isTunnel)
                t.expectEqual(en0.ipv4Addresses.map(\.description), ["192.168.1.23"])
                let tun = try t.require(interfaces.first { $0.name == "utun1024" })
                t.expect(tun.isUp && tun.isTunnel)
                t.expectEqual(tun.ipv4Addresses.map(\.description), ["198.18.0.1"])
                t.expectEqual(interfaces.first { $0.name == "utun0" }?.ipv4Addresses, [])
            },
            TestCase("B 组 utun7（文件末行）") { t in
                let interfaces = IfconfigParser.parse(try FixtureLoader.text(.b, "ifconfig.txt"))
                let utun7 = try t.require(interfaces.first { $0.name == "utun7" })
                t.expect(utun7.isUp)
                t.expectEqual(utun7.ipv4Addresses.map(\.description), ["10.9.0.2"])
            },
            TestCase("DOWN 接口与空输出") { t in
                let text = "utun3: flags=8050<POINTOPOINT,RUNNING,MULTICAST> mtu 1380\n\tinet 10.9.0.2 --> 10.9.0.2 netmask 0xffffffff\n"
                let iface = try t.require(IfconfigParser.parse(text).first)
                t.expect(!iface.isUp)
                t.expectEqual(iface.ipv4Addresses.map(\.description), ["10.9.0.2"])
                t.expectEqual(IfconfigParser.parse(""), [])
            },
        ])
    }
}

enum ScutilDictionaryParserTests {
    static var suite: TestSuite {
        TestSuite("Core.ScutilDictionaryParser", [
            TestCase("A 组主服务四个字典") { t in
                let values = try ScutilDictionaryParser.parseSequence(try FixtureLoader.text(.a, "dynstore-primary.txt"))
                t.expectEqual(values.count, 4)
                t.expectEqual(values[0]["PrimaryInterface"]?.stringValue, "en0")
                t.expectEqual(values[0]["PrimaryService"]?.stringValue, "8F3C2A10-5B7E-4D21-9C66-0A1B2C3D4E5F")
                t.expectEqual(values[1].serverAddresses, ["119.29.29.29"])
                t.expectEqual(values[1]["__CONFIGURATION_ID__"]?.stringValue,
                              "Default: 8F3C2A10-5B7E-4D21-9C66-0A1B2C3D4E5F 0")
                t.expectEqual(values[2]["HTTPEnable"]?.stringValue, "0")
                t.expectEqual(values[2]["ExceptionsList"], .array([]))
                t.expectEqual(values[2].serverAddresses, ["119.29.29.29"])
                t.expectEqual(values[3].serverAddresses, ["192.168.1.1"])
            },
            TestCase("C 组 Setup DNS 为 [\"\"]，视为空") { t in
                let values = try ScutilDictionaryParser.parseSequence(try FixtureLoader.text(.c, "dynstore-primary.txt"))
                t.expectEqual(values.count, 4)
                t.expectEqual(values[2]["ServerAddresses"]?.stringArray, [""])
                t.expectEqual(values[2].serverAddresses, [])
                t.expectEqual(values[1]["__IF_INDEX__"]?.stringValue, "15")
            },
            TestCase("跳过 == 标题行") { t in
                let values = try ScutilDictionaryParser.parseSequence(try FixtureLoader.text(.a, "dynstore-service-dns.txt"))
                t.expectEqual(values.count, 2)
                t.expectEqual(values[1]["InterfaceName"]?.stringValue, "utun3")
                t.expectEqual(values[1].serverAddresses, ["100.100.100.100"])
            },
            TestCase("空输出与未闭合") { t in
                t.expectEqual(try ScutilDictionaryParser.parseSequence(""), [])
                t.expectThrows(try ScutilDictionaryParser.parse(""))
                t.expectThrows(try ScutilDictionaryParser.parse("<dictionary> {\n  A : 1\n"))
                t.expectThrows(try ScutilDictionaryParser.parse("<dictionary> {\n  garbage\n}"))
                let missingKey = try ScutilDictionaryParser.parse("<dictionary> {\n  Other : x\n}")
                t.expectEqual(missingKey.serverAddresses, [])
            },
        ])
    }
}
