import Darwin
import Foundation
import TunCanaryCore
import TunCanarySystem

/// 各采集器测试：进程识别、接口、SCDynamicStore 映射、文件读取。不读取本机真实的 Clash 配置或VPN 文件。
enum CollectorTests {
    static let home = "/Users/tester"
    static let paths = KnownPaths(homeDirectory: home)

    /// 把 fixture 中的 `scutil show` 值转换为 SCDynamicStore 返回的字典形态。
    static func plist(_ value: ScutilValue) -> Any {
        switch value {
        case .string(let text): return text
        case .array(let list): return list.map(plist)
        case .dictionary(let dict): return dict.mapValues(plist)
        }
    }

    static var processSuite: TestSuite {
        TestSuite("System.ProcessScanner", [
            TestCase("按可执行文件路径识别相关进程") { t in
                let matcher = RelevantProcessMatcher(paths: paths, adapters: [FixtureLoader.vpnAdapter])
                let support = FixtureLoader.vpnExecutables[0]
                t.expectEqual(matcher.match(executablePath: support)?.kind, .vpn("example"))
                t.expectEqual(matcher.match(executablePath: FixtureLoader.vpnExecutables[1])?.kind, .vpn("example"))
                t.expectEqual(matcher.match(executablePath: "/Library/Application Support/clash-verge-service/cores/verge-mihomo")?.kind, .mihomo)
                t.expectEqual(matcher.match(executablePath: "/Applications/Clash Verge.app/Contents/MacOS/clash-verge")?.kind, .clashVerge)
            },
            TestCase("数据卷前缀的路径改写成配置中的写法") { t in
                let matcher = RelevantProcessMatcher(paths: paths, adapters: [FixtureLoader.vpnAdapter])
                let matched = matcher.match(executablePath: "/System/Volumes/Data" + FixtureLoader.vpnExecutables[0])
                t.expectEqual(matched?.kind, .vpn("example"))
                t.expectEqual(matched?.path, FixtureLoader.vpnExecutables[0])
            },
            TestCase("不相关或只是名字相近的进程不识别") { t in
                let matcher = RelevantProcessMatcher(paths: paths, adapters: [FixtureLoader.vpnAdapter])
                // 命令行含 VPN 可执行文件名的 grep：按路径识别时是 /usr/bin/grep。
                t.expectNil(matcher.match(executablePath: "/usr/bin/grep"))
                t.expectNil(matcher.match(executablePath: "/opt/other/example-tunnel"))
                t.expectNil(matcher.match(executablePath: "/Users/other/Library/Application Support/Example VPN/bin/example-tunnel"))
                t.expectNil(matcher.match(executablePath: "/usr/local/bin/verge-mihomo-alpha"))
                t.expectNil(matcher.match(executablePath: "/Applications/Clash Verge.app/Contents/MacOS/clash-verge-service"))
                t.expectNil(matcher.match(executablePath: ""))
            },
            TestCase("能列出当前进程及其路径") { t in
                let all = try ProcessScanner().listAll()
                t.expect(all.count > 10, "进程数 \(all.count)")
                let me = try t.require(all.first { $0.pid == getpid() })
                t.expectEqual(me.executableName, "TunCanarySelfTest")
                t.expectEqual(ProcessScanner.executablePath(of: getpid()), me.executablePath)
                t.expectNil(ProcessScanner.executablePath(of: -1))
            },
            TestCase("相关进程列表只含三类进程") { t in
                let matcher = RelevantProcessMatcher(paths: KnownPaths.currentUser())
                let list = try ProcessScanner().relevantProcesses(matcher: matcher)
                for entry in list {
                    t.expect(matcher.match(executablePath: entry.executablePath ?? "") != nil, "不应包含 pid \(entry.pid)")
                }
            },
        ])
    }

    static var interfaceSuite: TestSuite {
        TestSuite("System.InterfaceScanner", [
            TestCase("getifaddrs 能取到回环接口") { t in
                let interfaces = try InterfaceScanner().scan()
                let loopback = try t.require(interfaces.first { $0.name == "lo0" })
                t.expect(loopback.isUp)
                t.expect(loopback.flags.contains("LOOPBACK"))
                t.expect(loopback.ipv4Addresses.contains(IPv4("127.0.0.1")!))
                t.expectEqual(Set(interfaces.map(\.name)).count, interfaces.count, "同名接口已合并")
            },
            TestCase("标志名与 ifconfig 一致") { t in
                let flags = UInt32(IFF_UP | IFF_POINTOPOINT | IFF_RUNNING | IFF_MULTICAST)
                t.expectEqual(InterfaceScanner.flagNames(flags), ["UP", "POINTOPOINT", "RUNNING", "MULTICAST"])
                t.expectEqual(InterfaceScanner.flagNames(0), [])
            },
        ])
    }

    static var dynamicStoreSuite: TestSuite {
        TestSuite("System.DynamicStore", [
            TestCase("保存值 [\"\"] 规范化为空（合成场景 C）") { t in
                let values = try ScutilDictionaryParser.parseSequence(try FixtureLoader.text(.c, "dynstore-primary.txt"))
                t.expectEqual(values.count, 4)
                let service = DynamicStoreMapping.primaryService(
                    globalIPv4: plist(values[0]) as? [String: Any],
                    serviceSetup: ["UserDefinedName": "Wi-Fi"],
                    interfaceSetup: nil,
                    setupDNS: plist(values[2]) as? [String: Any],
                    stateDNS: plist(values[3]) as? [String: Any]
                )
                let info = try t.require(service.value)
                t.expectEqual(info.serviceID, "8F3C2A10-5B7E-4D21-9C66-0A1B2C3D4E5F")
                t.expectEqual(info.name, "Wi-Fi")
                t.expectEqual(info.interfaceName, "en0")
                t.expectEqual(info.savedDNS, [])
                t.expectEqual(info.stateDNS, ["192.168.1.1"])
                t.expectEqual(DynamicStoreMapping.globalDNS(plist(values[1]) as? [String: Any]), .collected(["192.168.1.1"]))
            },
            TestCase("合成场景 A、B 的保存值") { t in
                for (scenario, expected) in [(FixtureLoader.Scenario.a, ["119.29.29.29"]), (.b, ["10.9.0.53"])] {
                    let values = try ScutilDictionaryParser.parseSequence(try FixtureLoader.text(scenario, "dynstore-primary.txt"))
                    let saved = DynamicStoreMapping.serverAddresses(plist(values[2]) as? [String: Any])
                    t.expectEqual(saved, expected, scenario.rawValue)
                }
            },
            TestCase("服务名与接口名的回退") { t in
                t.expectEqual(DynamicStoreMapping.serviceName(serviceSetup: ["UserDefinedName": "USB 10/100/1000 LAN"],
                                                              interfaceSetup: ["UserDefinedName": "x"]), "USB 10/100/1000 LAN")
                t.expectEqual(DynamicStoreMapping.serviceName(serviceSetup: [:], interfaceSetup: ["UserDefinedName": "Ethernet"]), "Ethernet")
                t.expectNil(DynamicStoreMapping.serviceName(serviceSetup: ["UserDefinedName": " "], interfaceSetup: nil))
                let service = DynamicStoreMapping.primaryService(
                    globalIPv4: ["PrimaryService": "ABC"],
                    serviceSetup: nil,
                    interfaceSetup: ["DeviceName": "en7"],
                    setupDNS: nil,
                    stateDNS: ["ServerAddresses": ["192.168.1.1", " ", "192.168.1.1"]]
                )
                t.expectEqual(service, .collected(PrimaryServiceInfo(serviceID: "ABC", name: nil, interfaceName: "en7",
                                                                     savedDNS: [], stateDNS: ["192.168.1.1"])))
            },
            TestCase("没有主服务或全局 DNS 时为失败") { t in
                let none = DynamicStoreMapping.primaryService(globalIPv4: nil, serviceSetup: nil, interfaceSetup: nil,
                                                              setupDNS: nil, stateDNS: nil)
                t.expectContains(none.failureReason ?? "", "没有主网络服务")
                let empty = DynamicStoreMapping.primaryService(globalIPv4: ["PrimaryInterface": "en0"], serviceSetup: nil,
                                                               interfaceSetup: nil, setupDNS: nil, stateDNS: nil)
                t.expectContains(empty.failureReason ?? "", "PrimaryService")
                t.expectNotNil(DynamicStoreMapping.globalDNS(nil).failureReason)
                t.expectEqual(DynamicStoreMapping.globalDNS(["ServerAddresses": [""]]), .collected([]))
            },
            TestCase("真实读取不抛错且字段已规范化") { t in
                let result = DynamicStoreReader().read()
                if let service = result.primaryService.value {
                    t.expect(!service.serviceID.isEmpty)
                    t.expect(!service.savedDNS.contains(""))
                } else {
                    t.expect(result.primaryService.failureReason != nil, "未读到时应带原因")
                }
            },
        ])
    }

    static var fileSuite: TestSuite {
        TestSuite("System.FileReaders", [
            TestCase("DNS 守护进程：未安装、已安装、文件缺失或损坏") { t in
                let dir = try SystemTestKit.makeTemporaryDirectory()
                defer { SystemTestKit.removeDirectory(dir) }
                let paths = DNSGuardPaths(root: dir.path)
                let reader = DNSGuardReader(paths: paths)
                t.expectEqual(reader.read(), .collected(.notInstalled))

                let manager = FileManager.default
                try manager.createDirectory(atPath: (paths.launchDaemonFile as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
                try "<plist/>".write(toFile: paths.launchDaemonFile, atomically: true, encoding: .utf8)
                t.expectEqual(reader.read(), .collected(DNSGuardSnapshot(installed: true)), "只有 LaunchDaemon")

                try manager.createDirectory(atPath: paths.supportDirectory, withIntermediateDirectories: true)
                try #"{"targetDNS":["192.0.2.53"],"connectedTakeover":{"enabled":false}}"#
                    .write(toFile: paths.configFile, atomically: true, encoding: .utf8)
                try #"{"lastRun":{"date":"2026-09-26T12:00:00Z","phase":"disconnected","outcome":"compliant"}}"#
                    .write(toFile: paths.stateFile, atomically: true, encoding: .utf8)
                try """
                {"date":"2026-09-26T11:59:00Z","phase":"disconnected","outcome":"written"}
                broken
                {"date":"2026-09-26T12:00:00Z","phase":"disconnected","outcome":"compliant"}
                """.write(toFile: paths.eventLogFile, atomically: true, encoding: .utf8)
                let snapshot = try t.require(reader.read().value)
                t.expect(snapshot.installed)
                t.expectEqual(snapshot.config, .collected(DNSGuardConfigSummary(targetDNS: ["192.0.2.53"])))
                t.expectEqual(snapshot.state.value?.lastRun?.outcome, .compliant)
                t.expectEqual(snapshot.recentEvents.map(\.outcome), [.written, .compliant])

                try "{}".write(toFile: paths.configFile, atomically: true, encoding: .utf8)
                chmod(paths.stateFile, 0o000)
                let broken = try t.require(reader.read().value)
                t.expectEqual(broken.config, .failed(reason: "配置缺少 targetDNS"))
                t.expectEqual(broken.state, .failed(reason: "权限不足"))
            },
            TestCase("不存在、不可读与目录分开表示") { t in
                let dir = try SystemTestKit.makeTemporaryDirectory()
                defer { SystemTestKit.removeDirectory(dir) }
                let file = dir.appendingPathComponent("a.txt")
                try "hello".write(to: file, atomically: true, encoding: .utf8)
                t.expectEqual(LocalFileReader.read(file.path), .data(Data("hello".utf8)))
                t.expectEqual(LocalFileReader.read(dir.appendingPathComponent("missing.txt").path), .missing)
                t.expectEqual(LocalFileReader.read(dir.appendingPathComponent("no/such/dir.txt").path), .missing)
                t.expectEqual(LocalFileReader.read(dir.path), .failed("不是普通文件"))
                chmod(file.path, 0o000)
                t.expectEqual(LocalFileReader.read(file.path), .failed("权限不足"))
                chmod(file.path, 0o600)
                t.expectEqual(LocalFileReader.read(file.path, maxBytes: 3), .failed("文件过大（5 字节）"))
            },
            TestCase("VPN 状态文件：存在、不存在、不可读") { t in
                let dir = try SystemTestKit.makeTemporaryDirectory()
                defer { SystemTestKit.removeDirectory(dir) }
                let file = dir.appendingPathComponent("state/session.json").path
                let reader = VPNStatusFileReader(path: file, fields: VPNStatusFileParserTests.fields)
                t.expectEqual(reader.read(), .missing)

                try FileManager.default.createDirectory(atPath: dir.appendingPathComponent("state").path,
                                                        withIntermediateDirectories: true)
                let json = """
                {"session":{"active":true,"pending":false,"address":"10.60.0.5","resolvers":"10.60.2.2,10.60.2.3",
                 "password":"should-not-be-read"},"config":{"server":"vpn.example"}}
                """
                try json.write(toFile: file, atomically: true, encoding: .utf8)
                let state = reader.read()
                t.expectEqual(state, .present(VPNStatus(status: true, connecting: false, tunnelIP: "10.60.0.5",
                                                           dnsServers: ["10.60.2.2", "10.60.2.3"])))

                chmod(file, 0o000)
                t.expectEqual(reader.read(), .unreadable(reason: "权限不足"))
                chmod(file, 0o600)

                try "{not json".write(toFile: file, atomically: true, encoding: .utf8)
                t.expectEqual(reader.read(), .unreadable(reason: VPNStatusFileParseError.invalidJSON.message))
            },
            TestCase("Clash 配置：读取合成配置") { t in
                let dir = try SystemTestKit.makeTemporaryDirectory()
                defer { SystemTestKit.removeDirectory(dir) }
                try SystemTestKit.writeClashConfig(home: dir, verge: FixtureLoader.vergeYAML(),
                                                   clash: FixtureLoader.clashVergeYAML())
                let config = try t.require(ClashConfigReader(paths: KnownPaths(homeDirectory: dir.path)).read().value)
                t.expectEqual(config, FixtureLoader.clashConfig())
                t.expectEqual(config.dnsListenPort, 7874)
                t.expectEqual(config.tunConfigured, true)
            },
            TestCase("Clash 配置：缺失或不可读时失败，原因只含文件名") { t in
                let dir = try SystemTestKit.makeTemporaryDirectory()
                defer { SystemTestKit.removeDirectory(dir) }
                let paths = KnownPaths(homeDirectory: dir.path)
                let missingBoth = ClashConfigReader(paths: paths).read()
                t.expectEqual(missingBoth.failureReason, "未找到 verge.yaml；未找到 clash-verge.yaml")

                try SystemTestKit.writeClashConfig(home: dir, verge: nil, clash: FixtureLoader.clashVergeYAML())
                let missingVerge = ClashConfigReader(paths: paths).read()
                let reason = missingVerge.failureReason ?? ""
                t.expectEqual(reason, "未找到 verge.yaml")
                t.expectNotContains(reason, dir.path)
                t.expectNotContains(reason, "secret")

                try SystemTestKit.writeClashConfig(home: dir, verge: FixtureLoader.vergeYAML(), clash: nil)
                chmod(paths.clashVergeConfigFile, 0o000)
                t.expectEqual(ClashConfigReader(paths: paths).read().failureReason, "无法读取 clash-verge.yaml：权限不足")
                chmod(paths.clashVergeConfigFile, 0o600)

                try Data([0xFF, 0xFE, 0x00]).write(to: URL(fileURLWithPath: paths.clashVergeConfigFile))
                t.expectEqual(ClashConfigReader(paths: paths).read().failureReason, "clash-verge.yaml 不是 UTF-8 文本")
            },
        ])
    }
}

private extension TestContext {
    func expectNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
        if value == nil { fail("期望非 nil", file: file, line: line) }
    }
}
