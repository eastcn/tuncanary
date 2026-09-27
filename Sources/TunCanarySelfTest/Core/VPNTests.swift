import Foundation
import TunCanaryCore

/// 声明式 VPN 适配器：证据合并、隧道识别、多适配器汇总、配置校验与加载。全部使用合成数据。
enum VPNTests {
    static let home = "/Users/tester"
    static let paths = KnownPaths(homeDirectory: home)
    static let fakeRange = IPv4CIDR("198.18.0.1/16")!

    static let example = VPNAdapterConfig(
        id: "example",
        name: "Example VPN",
        process: .init(executablePaths: ["~/Library/Application Support/Example VPN/bin/example-tunnel"]),
        statusFile: .init(path: "~/Library/Application Support/Example VPN/state.json",
                          connected: "/session/active", tunnelIP: "/session/address", dns: "/session/resolvers"))

    static let other = VPNAdapterConfig(
        id: "other",
        name: "Other VPN",
        process: .init(executablePaths: ["/opt/other-vpn/bin/other-vpn"]),
        tunnel: .init(cidr: "172.20.0.0/16"))

    static let proxyTun = InterfaceInfo(name: "utun1024", isUp: true, ipv4Addresses: [IPv4("198.18.0.1")!])
    static let overlay = InterfaceInfo(name: "utun3", isUp: true, ipv4Addresses: [IPv4("100.80.1.2")!])

    static func routes(_ count: Int, to interface: String, base: Int = 1) -> [RouteEntry] {
        (0..<count).map { RouteEntry(destination: "10.\(base).\($0)/24", gateway: "10.\(base).0.1", interfaceName: interface) }
    }

    /// 基础快照：只有代理 TUN 和一个叠加网络隧道，没有 VPN。
    static func baseSnapshot() -> LocalSnapshot {
        LocalSnapshot(
            collectedAt: Date(timeIntervalSince1970: 1_790_424_000),
            processes: .collected([]),
            interfaces: .collected([proxyTun, overlay]),
            routes: .collected(routes(4, to: "utun1024", base: 50) + routes(3, to: "utun3", base: 60)))
    }

    /// Example VPN 已连接：进程、隧道、路由和状态文件都在。
    static func exampleConnected() -> LocalSnapshot {
        var snapshot = baseSnapshot()
        snapshot.processes = .collected([ProcessEntry(pid: 900, executablePath: example.executablePaths(home: home)[0])])
        snapshot.interfaces = .collected([proxyTun, overlay,
                                          InterfaceInfo(name: "utun7", isUp: true, ipv4Addresses: [IPv4("10.9.0.2")!])])
        snapshot.routes = .collected(snapshot.routes.value! + routes(12, to: "utun7", base: 9))
        snapshot.vpnStatusFiles[example.id] = .present(
            VPNStatus(status: true, connecting: false, tunnelIP: "10.9.0.2", dnsServers: ["10.9.0.53", "10.9.0.54"]))
        return snapshot
    }

    static func analyze(_ snapshot: LocalSnapshot, _ adapters: [VPNAdapterConfig]) -> VPNAnalysis {
        VPNAnalyzer(adapters: adapters, homeDirectory: home)
            .analyze(snapshot, proxyInterface: "utun1024", fakeIPRange: fakeRange)
    }

    static var suite: TestSuite {
        TestSuite("Core.VPN", [
            TestCase("合并规则：连接、断开与各类未确认") { t in
                func merge(_ required: Bool?, _ tunnel: Bool?, _ routes: Bool?, _ advisory: Bool? = nil)
                    -> (VPNConnectionState, VPNEvidenceMerger.Reason?) {
                    let result = VPNEvidenceMerger.merge([
                        VPNSignal(.required, required), VPNSignal(.supporting, tunnel),
                        VPNSignal(.supporting, routes), VPNSignal(.advisory, advisory),
                    ])
                    return (result.state, result.reason)
                }
                t.expect(merge(true, true, nil) == (.connected, nil), "佐证之一为真即可")
                t.expect(merge(true, false, true) == (.connected, nil))
                t.expect(merge(false, false, false) == (.disconnected, nil))
                t.expect(merge(nil, false, false) == (.unconfirmed, .requiredUnknown))
                t.expect(merge(false, false, nil) == (.unconfirmed, .supportingUnknown))
                t.expect(merge(true, false, false) == (.unconfirmed, .requiredWithoutSupport))
                t.expect(merge(false, true, false) == (.unconfirmed, .supportWithoutRequired))
                t.expect(merge(true, true, true, false) == (.unconfirmed, .advisoryContradicts(claimsConnected: false)))
                t.expect(merge(false, false, false, true) == (.unconfirmed, .advisoryContradicts(claimsConnected: true)))
                t.expect(merge(true, true, true, true) == (.connected, nil), "参考信号一致时不改判")
            },
            TestCase("没有适配器、没有其他隧道 → 已断开，叠加网络不参与") { t in
                let result = analyze(baseSnapshot(), [])
                t.expectEqual(result.state, .disconnected)
                t.expectEqual(result.title, "VPN")
                t.expectEqual(result.unrecognizedTunnels, [])
                t.expectEqual(result.evidence, ["未配置 VPN 适配器，也未发现其他 VPN 隧道"])
            },
            TestCase("未识别的隧道带路由 → 未确认") { t in
                var snapshot = baseSnapshot()
                snapshot.interfaces = .collected([proxyTun, overlay,
                                                  InterfaceInfo(name: "utun8", isUp: true, ipv4Addresses: [IPv4("10.44.0.9")!])])
                snapshot.routes = .collected(snapshot.routes.value! + routes(2, to: "utun8", base: 44))
                let result = analyze(snapshot, [])
                t.expectEqual(result.state, .unconfirmed)
                t.expectEqual(result.unrecognizedTunnels, ["utun8"])
                t.expectEqual(result.evidence.first, "发现未识别的隧道，无法确认 VPN 状态")
                t.expect(result.evidence.contains("未识别的隧道 utun8（10.44.0.9，路由 2 条）"), "\(result.evidence)")
                // 没有路由指向的隧道、DOWN 的隧道都不算。
                snapshot.routes = baseSnapshot().routes
                t.expectEqual(analyze(snapshot, []).state, .disconnected)
            },
            TestCase("单个适配器：已连接，标题用适配器名，报告 VPN DNS") { t in
                let result = analyze(exampleConnected(), [example])
                t.expectEqual(result.state, .connected)
                t.expectEqual(result.title, "Example VPN")
                t.expectEqual(result.connectedDNS, ["10.9.0.53", "10.9.0.54"])
                t.expect(result.connectedReportsDNS)
                t.expectEqual(result.claimedTunnels, ["utun7"])
                t.expect(result.evidence.contains("VPN 进程运行中（pid 900）"), "\(result.evidence)")
                t.expect(result.evidence.contains("隧道 utun7 已启用（10.9.0.2，按状态文件中的隧道 IP 识别）"), "\(result.evidence)")
                t.expect(result.evidence.contains("隧道路由 12 条"), "\(result.evidence)")
            },
            TestCase("单个适配器：进程退出、隧道消失 → 已断开，状态文件保留旧 DNS") { t in
                var snapshot = baseSnapshot()
                snapshot.vpnStatusFiles[example.id] = .present(
                    VPNStatus(status: false, connecting: false, tunnelIP: "10.9.0.2", dnsServers: ["10.9.0.53"]))
                let result = analyze(snapshot, [example])
                t.expectEqual(result.state, .disconnected)
                t.expectEqual(result.connectedDNS, [])
                t.expectEqual(result.knownDNS, ["10.9.0.53"])
            },
            TestCase("多个适配器：证据按名称分组，任一未确认则汇总未确认") { t in
                var snapshot = exampleConnected()
                let result = analyze(snapshot, [example, other])
                t.expectEqual(result.state, .connected)
                t.expectEqual(result.title, "VPN")
                t.expect(result.evidence.contains("Example VPN：VPN 进程运行中（pid 900）"), "\(result.evidence)")
                t.expect(result.evidence.contains("Other VPN：未发现 VPN 进程"), "\(result.evidence)")

                // Other VPN 进程在，但没有它的隧道 → 未确认。
                snapshot.processes = .collected(snapshot.processes.value! + [ProcessEntry(pid: 901, executablePath: "/opt/other-vpn/bin/other-vpn")])
                t.expectEqual(analyze(snapshot, [example, other]).state, .unconfirmed)

                // 按配置网段识别出 Other VPN 的隧道 → 两者都已连接，DNS 只取报告了 DNS 的适配器。
                snapshot.interfaces = .collected(snapshot.interfaces.value! +
                    [InterfaceInfo(name: "utun9", isUp: true, ipv4Addresses: [IPv4("172.20.3.4")!])])
                let both = analyze(snapshot, [example, other])
                t.expectEqual(both.state, .connected)
                t.expectEqual(both.claimedTunnels, ["utun7", "utun9"])
                t.expectEqual(both.connectedDNS, ["10.9.0.53", "10.9.0.54"])
            },
            TestCase("已认领的隧道不会被另一个适配器按路由数量重复识别") { t in
                var snapshot = exampleConnected()
                var fallback = other
                fallback.tunnel = VPNAdapterConfig.Tunnel(minRoutes: 5)
                snapshot.processes = .collected(snapshot.processes.value! + [ProcessEntry(pid: 901, executablePath: "/opt/other-vpn/bin/other-vpn")])
                let result = analyze(snapshot, [example, fallback])
                let otherResult = try t.require(result.adapters.last)
                t.expectNil(otherResult.tunnelName)
                t.expectEqual(otherResult.state, .unconfirmed)
            },
            TestCase("判定引擎：VPN 已连接但未配置 DNS 字段 → 不检查 DNS") { t in
                var adapter = example
                adapter.statusFile = nil
                var snapshot = exampleConnected()
                snapshot.primaryService = .collected(PrimaryServiceInfo(
                    serviceID: "S1", name: "Wi-Fi", interfaceName: "en0", savedDNS: ["192.0.2.53"], stateDNS: []))
                let result = LocalEvaluator(paths: paths, adapters: [adapter])
                    .evaluate(snapshot: snapshot, settings: AppSettings(), inGracePeriod: false)
                t.expectEqual(result.vpnState, .connected)
                t.expectEqual(result.card(.primaryDNS)?.severity, .ok)
                t.expectEqual(result.card(.primaryDNS)?.conclusion, "VPN 已连接（未配置 VPN DNS，不检查）")
                t.expect(result.intranetProbeEnabled)
            },
            TestCase("判定引擎：适配器配置问题显示在 VPN 卡") { t in
                let result = LocalEvaluator(paths: paths, adapters: [], adapterProblems: ["broken.json：缺少字段 id"])
                    .evaluate(snapshot: baseSnapshot(), settings: AppSettings(), inGracePeriod: false)
                let card = try t.require(result.card(.vpn))
                t.expectEqual(card.conclusion, "未发现 VPN")
                t.expect(card.evidence.contains("适配器配置无效：broken.json：缺少字段 id"), "\(card.evidence)")
            },
            TestCase("配置校验") { t in
                t.expectEqual(example.validate(), [])
                var bad = example
                bad.id = "has space"
                bad.name = " "
                bad.process.executablePaths = ["relative/path"]
                bad.statusFile?.connected = "session/active"
                bad.tunnel = VPNAdapterConfig.Tunnel(cidr: "10.0.0.0/40", minRoutes: 0)
                t.expectEqual(bad.validate(), [
                    .idInvalid, .nameInvalid, .executablePathInvalid("relative/path"),
                    .pointerInvalid("session/active"), .tunnelCIDRInvalid("10.0.0.0/40"), .minRoutesInvalid,
                ])
                bad.process.executablePaths = []
                t.expect(bad.validate().contains(.executablePathsEmpty))
            },
            TestCase("从目录加载：按文件名排序，跳过无效与重复") { t in
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("np-adapters-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let encoder = JSONEncoder()
                try encoder.encode(other).write(to: dir.appendingPathComponent("b-other.json"))
                try encoder.encode(example).write(to: dir.appendingPathComponent("a-example.json"))
                try encoder.encode(example).write(to: dir.appendingPathComponent("c-duplicate.json"))
                try Data(#"{"id":"x"}"#.utf8).write(to: dir.appendingPathComponent("d-broken.json"))
                try Data("ignored".utf8).write(to: dir.appendingPathComponent("notes.txt"))

                let set = VPNAdapterStore(directory: dir.path).load()
                t.expectEqual(set.adapters.map(\.id), ["example", "other"])
                t.expectEqual(set.problems, [
                    "c-duplicate.json：id“example”与其他适配器重复",
                    "d-broken.json：不是有效的适配器配置（缺少字段 name）",
                ])
                t.expectEqual(VPNAdapterStore(directory: dir.appendingPathComponent("missing").path).load(), VPNAdapterSet())
            },
            TestCase("目录指纹：增、删、改名、原地改写都会触发重新加载") { t in
                let parent = FileManager.default.temporaryDirectory
                    .appendingPathComponent("np-adapters-\(UUID().uuidString)", isDirectory: true)
                let dir = parent.appendingPathComponent("adapters", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: parent) }
                let registry = VPNAdapterRegistry(store: VPNAdapterStore(directory: dir.path))
                t.expectEqual(registry.current, VPNAdapterSet())
                t.expectNil(registry.reloadIfChanged(), "目录不存在且没有变化")

                // 目录原本不存在，之后创建并写入。
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                let exampleFile = dir.appendingPathComponent("a-example.json")
                try encoder.encode(example).write(to: exampleFile)
                t.expectEqual(registry.reloadIfChanged()?.adapters.map(\.id), ["example"])
                t.expectNil(registry.reloadIfChanged(), "没有变化时不重新加载")

                // 新增文件；非 .json 文件不影响指纹。
                try encoder.encode(other).write(to: dir.appendingPathComponent("b-other.json"))
                t.expectEqual(registry.reloadIfChanged()?.adapters.map(\.id), ["example", "other"])
                try Data("ignored".utf8).write(to: dir.appendingPathComponent("notes.txt"))
                t.expectNil(registry.reloadIfChanged())

                // 原地改写（同一个 inode）。
                var renamed = example
                renamed.name = "Example VPN 2"
                let handle = try FileHandle(forWritingTo: exampleFile)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: try encoder.encode(renamed))
                try handle.close()
                t.expectEqual(registry.reloadIfChanged()?.adapters.map(\.name), ["Example VPN 2", "Other VPN"])

                // 改名影响排序；删除后不再加载。
                try FileManager.default.moveItem(at: exampleFile, to: dir.appendingPathComponent("c-example.json"))
                t.expectEqual(registry.reloadIfChanged()?.adapters.map(\.id), ["other", "example"])
                try FileManager.default.removeItem(at: dir.appendingPathComponent("b-other.json"))
                t.expectEqual(registry.reloadIfChanged()?.adapters.map(\.id), ["example"])
                t.expectEqual(registry.current.adapters.map(\.id), ["example"])

                // 强制重新加载不比对指纹。
                t.expectEqual(registry.reload().adapters.map(\.id), ["example"])
            },
        ])
    }
}
