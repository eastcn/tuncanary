import Foundation
import TunCanaryCore
import TunCanarySystem

/// 快照采集测试：临时 home 中放合成配置，Mihomo DNS 指向本机回环上的测试服务，关闭系统解析 canary。
/// 接口、路由、解析器与 SCDynamicStore 读取的是本机真实状态（只读、不访问网络），只断言结构。
enum SnapshotProviderTests {
    static let collectedAt = Date(timeIntervalSince1970: 1_790_424_000)

    static func provider(home: URL) -> SystemSnapshotProvider {
        let configuration = SystemSnapshotProvider.Configuration(
            paths: KnownPaths(homeDirectory: home.path),
            adapters: [FixtureLoader.vpnAdapter],
            mihomoDNSTimeout: 1,
            resolvesCanary: false
        )
        return SystemSnapshotProvider(configuration: configuration, now: { collectedAt })
    }

    static var suite: TestSuite {
        TestSuite("System.SnapshotProvider", [
            TestCase("合成配置：各项都有结果，Mihomo DNS 走配置中的端口", timeout: 10) { t in
                let home = try SystemTestKit.makeTemporaryDirectory()
                defer { SystemTestKit.removeDirectory(home) }
                let server = try SystemTestUDPServer()
                defer { server.close() }
                try SystemTestKit.writeClashConfig(home: home, verge: FixtureLoader.vergeYAML(),
                                                   clash: SystemTestKit.clashYAML(port: server.port))
                server.serveOnce { query in [SystemTestKit.makeAResponse(to: query, answers: [IPv4("198.18.0.26")!])] }

                let report = await provider(home: home).collectReport()
                let snapshot = report.snapshot
                t.expectEqual(snapshot.collectedAt, collectedAt)
                t.expectEqual(snapshot.clashConfig.value?.dnsListenPort, server.port)
                guard case .success(let port, _, let answers) = snapshot.mihomoDNS else {
                    t.fail("Mihomo DNS 应为 success：\(snapshot.mihomoDNS)")
                    return
                }
                t.expectEqual(port, server.port)
                t.expectEqual(answers, [IPv4("198.18.0.26")!])
                t.expectEqual(snapshot.vpnStatusFiles["example"], .missing)
                t.expectEqual(snapshot.canary, .notTested)
                t.expect(snapshot.processes.isCollected)
                t.expect(snapshot.mihomoRunning.isCollected)
                t.expect(!(snapshot.interfaces.value ?? []).isEmpty)
                t.expect(snapshot.routes.isCollected, "netstat：\(snapshot.routes)")
                t.expect(snapshot.resolvers.isCollected, "scutil：\(snapshot.resolvers)")
                t.expect(snapshot.primaryService != .notCollected)
                t.expect(snapshot.globalDNS != .notCollected)
                t.expectEqual(Set(report.itemDurations.keys), Set(SnapshotItem.allCases))
                t.expect(report.totalDuration < 3, "耗时 \(report.totalDuration)")
            },
            TestCase("手动模式：不读配置文件，按设置的端口查询代理 DNS", timeout: 10) { t in
                let home = try SystemTestKit.makeTemporaryDirectory()
                defer { SystemTestKit.removeDirectory(home) }
                let server = try SystemTestUDPServer()
                defer { server.close() }
                server.serveOnce { query in [SystemTestKit.makeAResponse(to: query, answers: [IPv4("198.18.0.30")!])] }
                let manual = ManualProxyConfig(fakeIPRange: "198.18.0.0/15", dnsPort: server.port,
                                               coreProcessName: "no-such-core-process")
                let configuration = SystemSnapshotProvider.Configuration(
                    paths: KnownPaths(homeDirectory: home.path),
                    proxySource: { ProxySource(client: .manual, manual: manual, canaryHost: "probe.example.test") },
                    mihomoDNSTimeout: 1, resolvesCanary: false)
                let snapshot = await SystemSnapshotProvider(configuration: configuration).collectSnapshot()
                let config = try t.require(snapshot.clashConfig.value)
                t.expect(config.isManual)
                t.expectEqual(config.coreProcessName, "no-such-core-process")
                t.expectEqual(config.fakeIPRange?.description, "198.18.0.0/15")
                t.expectEqual(snapshot.mihomoRunning, .collected(false))
                guard case .success(let port, _, _) = snapshot.mihomoDNS else {
                    t.fail("代理 DNS 应为 success：\(snapshot.mihomoDNS)")
                    return
                }
                t.expectEqual(port, server.port)
                t.expectEqual(snapshot.canaryHost, "probe.example.test")

                // 不填端口和进程名：不查询 DNS，不判断进程。
                let bare = SystemSnapshotProvider.Configuration(
                    paths: KnownPaths(homeDirectory: home.path),
                    proxySource: { ProxySource(client: .manual, manual: ManualProxyConfig()) },
                    resolvesCanary: false)
                let bareSnapshot = await SystemSnapshotProvider(configuration: bare).collectSnapshot()
                t.expectEqual(bareSnapshot.mihomoDNS, .notApplicable)
                t.expectEqual(bareSnapshot.mihomoRunning, .notCollected)
            },
            TestCase("配置缺失：Clash 配置失败，Mihomo DNS 未采集", timeout: 10) { t in
                let home = try SystemTestKit.makeTemporaryDirectory()
                defer { SystemTestKit.removeDirectory(home) }
                let snapshot = await provider(home: home).collectSnapshot()
                t.expectEqual(snapshot.clashConfig.failureReason, "未找到 verge.yaml；未找到 clash-verge.yaml")
                t.expectEqual(snapshot.mihomoDNS, .notCollected)
                t.expectEqual(snapshot.vpnStatusFiles["example"], .missing)
            },
            TestCase("TUN 配置关闭：Mihomo DNS 不适用", timeout: 10) { t in
                let home = try SystemTestKit.makeTemporaryDirectory()
                defer { SystemTestKit.removeDirectory(home) }
                try SystemTestKit.writeClashConfig(home: home, verge: FixtureLoader.vergeYAML(tunMode: false),
                                                   clash: FixtureLoader.clashVergeYAML(tunEnable: false))
                let snapshot = await provider(home: home).collectSnapshot()
                t.expectEqual(snapshot.clashConfig.value?.tunConfigured, false)
                t.expectEqual(snapshot.mihomoDNS, .notApplicable)
            },
            TestCase("端口选择规则") { t in
                t.expectEqual(SystemSnapshotProvider.mihomoPort(for: FixtureLoader.clashConfig()), 7874)
                t.expectNil(SystemSnapshotProvider.mihomoPort(for: FixtureLoader.clashConfig(tunOn: false)))
                t.expectNil(SystemSnapshotProvider.mihomoPort(for: ClashConfig(tunEnabled: true)))
                t.expectEqual(SystemSnapshotProvider.mihomoPort(for: ClashConfig(dnsListenPort: 53)), 53, "TUN 开关未知时仍查询")
            },
            TestCase("端口无响应：noResponse", timeout: 10) { t in
                let home = try SystemTestKit.makeTemporaryDirectory()
                defer { SystemTestKit.removeDirectory(home) }
                let port = try SystemTestUDPServer.closedPort()
                try SystemTestKit.writeClashConfig(home: home, verge: FixtureLoader.vergeYAML(),
                                                   clash: SystemTestKit.clashYAML(port: port))
                let snapshot = await provider(home: home).collectSnapshot()
                t.expectEqual(snapshot.mihomoDNS, .noResponse(port: port))
            },
        ])
    }
}
