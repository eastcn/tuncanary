import Foundation
import TunCanaryCore

/// 从合成快照（`Tests/Fixtures/synthetic/`）构造 `LocalSnapshot`。其他模块的测试也可以复用。
///
/// - Clash 配置在代码中合成（TUN 开启、utun1024、端口 7874、fake-ip、198.18.0.1/16），
///   绝不读取本机真实配置。
/// - 代理 DNS 探测三组都成功；canary：A 为 fake-ip，B 未测，C 为真实地址。
/// - A 没有状态文件，按“不存在”处理。
enum FixtureLoader {
    enum Scenario: String, CaseIterable {
        /// VPN 断开，TUN 运行，DNS 为预期值。
        case a = "disconnected"
        /// VPN 已连接，DNS 为 VPN 下发的第一个地址。
        case b = "connected"
        /// VPN 刚断开，DNS 被清空。
        case c = "dns-cleared"
    }

    /// 测试用主目录（fixture 中的 `~` 展开为它）。
    static let testHome = "/Users/tester"
    static let paths = KnownPaths(homeDirectory: testHome)
    /// 合成的 Example VPN 适配器配置。
    static let vpnAdapter: VPNAdapterConfig = {
        let url = TestPaths.synthetic.appendingPathComponent("example-vpn.json")
        guard let data = try? Data(contentsOf: url), case .success(let config) = VPNAdapterStore.decode(data) else {
            fatalError("无法加载 Tests/Fixtures/synthetic/example-vpn.json")
        }
        return config
    }()
    static let evaluator = LocalEvaluator(paths: paths, adapters: [vpnAdapter])
    /// 传给 `CheckRunner`、`MonitorController` 的适配器集合。
    static var adapterSet: VPNAdapterSet { VPNAdapterSet(adapters: [vpnAdapter]) }
    /// Example VPN 的两个可执行文件路径（展开到测试主目录）。
    static var vpnExecutables: [String] { vpnAdapter.executablePaths(home: testHome) }
    /// 固定采集时间：2026-09-26 12:00:00 UTC。
    static let collectedAt = Date(timeIntervalSince1970: 1_790_424_000)

    static let fakeIPAnswer = IPv4("198.18.0.26")!
    static let realAnswer = IPv4("142.250.0.1")!
    static let mihomoSuccess = MihomoDNSProbeResult.success(port: 7874, latency: 0.008, answers: [fakeIPAnswer])

    /// 合成的 verge.yaml。
    static func vergeYAML(tunMode: Bool = true) -> String {
        """
        # 合成配置，仅供测试
        enable_tun_mode: \(tunMode)
        enable_system_proxy: false
        verge_mixed_port: 7897
        """
    }

    /// 合成的 clash-verge.yaml，混入 secret 等不应读取的字段。
    static func clashVergeYAML(tunEnable: Bool = true) -> String {
        """
        mixed-port: 7897
        secret: synthetic-secret-should-never-leak
        external-controller-unix: /tmp/verge-mihomo.sock
        proxies:
        - name: node-1
          server: 203.0.113.9
          password: synthetic-password
        tun:
          enable: \(tunEnable)
          stack: mixed
          device: utun1024
          auto-route: true
          dns-hijack:
          - any:53
        dns:
          enable: true
          ipv6: false
          listen: 0.0.0.0:7874
          enhanced-mode: fake-ip
          fake-ip-range: 198.18.0.1/16
          nameserver:
          - 119.29.29.29
        """
    }

    static func clashConfig(tunOn: Bool = true) -> ClashConfig {
        ClashConfigParser.parse(vergeYAML: vergeYAML(tunMode: tunOn), clashVergeYAML: clashVergeYAML(tunEnable: tunOn))
    }

    static func directory(_ scenario: Scenario) -> URL {
        TestPaths.synthetic.appendingPathComponent(scenario.rawValue, isDirectory: true)
    }

    static func text(_ scenario: Scenario, _ file: String) throws -> String {
        try String(contentsOf: directory(scenario).appendingPathComponent(file), encoding: .utf8)
    }

    /// 构造快照。
    static func snapshot(_ scenario: Scenario) throws -> LocalSnapshot {
        let processes = parsePS(try text(scenario, "ps.txt"), home: testHome)
        let (service, globalDNS) = try parsePrimary(try text(scenario, "dynstore-primary.txt"), serviceName: "Wi-Fi")

        let statusURL = directory(scenario).appendingPathComponent("vpn-status.json")
        let status: VPNStatusFileState
        if FileManager.default.fileExists(atPath: statusURL.path) {
            status = .present(try VPNStatusFileParser.parse(try Data(contentsOf: statusURL), fields: vpnAdapter.statusFile!))
        } else {
            status = .missing
        }

        let canary: CanaryResult
        switch scenario {
        case .a: canary = .resolved([fakeIPAnswer])
        case .b: canary = .notTested
        case .c: canary = .resolved([realAnswer])
        }

        return LocalSnapshot(
            collectedAt: collectedAt,
            clashConfig: .collected(clashConfig()),
            mihomoRunning: .collected(processes.contains { $0.executableName == KnownPaths.mihomoProcessName }),
            processes: .collected(processes),
            interfaces: .collected(IfconfigParser.parse(try text(scenario, "ifconfig.txt"))),
            routes: .collected(NetstatRouteParser.parse(try text(scenario, "netstat-rn.txt"))),
            resolvers: .collected(ScutilDNSParser.parse(try text(scenario, "scutil-dns.txt"))),
            vpnStatusFiles: [vpnAdapter.id: status],
            primaryService: .collected(service),
            globalDNS: .collected(globalDNS),
            mihomoDNS: mihomoSuccess,
            canary: canary
        )
    }

    /// 旧版的 9 个默认站点（百度、Google、Claude 为后台检测站点），供沿用旧行为的用例使用。
    static let legacySites: [Site] = {
        var claude = SiteCatalog.claude
        claude.isKey = true
        claude.inLightProbe = true
        var github = SiteCatalog.github
        github.isKey = false
        github.inLightProbe = false
        return [SiteCatalog.baidu, SiteCatalog.bilibili, SiteCatalog.jd, SiteCatalog.yahooJapan, SiteCatalog.sony,
                SiteCatalog.google, github, claude, SiteCatalog.chatgpt]
    }()

    /// 合成快照对应的设置：VPN 断开、TUN 运行时，DNS 应为 119.29.29.29；旧版 9 个站点。
    static let legacySettings = AppSettings(expectedDNS: ["119.29.29.29"], sites: legacySites)

    /// 评估快照（合成快照设置、宽限期外）。
    static func evaluate(_ snapshot: LocalSnapshot, settings: AppSettings = legacySettings, inGracePeriod: Bool = false) -> LocalAssessment {
        evaluator.evaluate(snapshot: snapshot, settings: settings, inGracePeriod: inGracePeriod)
    }

    /// 解析 ps.txt：`PID PPID USER STARTED(5 段) COMM`，COMM 为可执行文件路径，`~` 展开为 home。
    static func parsePS(_ text: String, home: String) -> [ProcessEntry] {
        var result: [ProcessEntry] = []
        for line in text.components(separatedBy: .newlines) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 9, let pid = Int32(fields[0]) else { continue }
            // 路径可能含空格：取第 9 个字段起的原文（Substring 与原串共享索引）。
            var path = String(line[fields[8].startIndex...]).trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("~/") { path = home + path.dropFirst() }
            result.append(ProcessEntry(pid: pid, executablePath: path))
        }
        return result
    }

    /// 解析 dynstore-primary.txt：首行 `PrimaryService=<id>`，之后依次为
    /// Global IPv4、Global DNS、Setup DNS、State DNS 四个字典。返回主服务和全局 DNS。
    static func parsePrimary(_ text: String, serviceName: String?) throws -> (PrimaryServiceInfo, [String]) {
        let firstLine = text.components(separatedBy: .newlines).first ?? ""
        let serviceID = firstLine.hasPrefix("PrimaryService=") ? String(firstLine.dropFirst("PrimaryService=".count)) : ""
        let values = try ScutilDictionaryParser.parseSequence(text)
        guard values.count == 4 else { throw FixtureError.unexpectedDynstore(values.count) }
        let globalIPv4 = values[0]
        let service = PrimaryServiceInfo(
            serviceID: serviceID,
            name: serviceName,
            interfaceName: globalIPv4["PrimaryInterface"]?.stringValue,
            savedDNS: values[2].serverAddresses,
            stateDNS: values[3].serverAddresses
        )
        return (service, values[1].serverAddresses)
    }

    enum FixtureError: Error {
        case unexpectedDynstore(Int)
    }

    // MARK: 常用修改

    /// 替换主服务的保存 DNS。
    static func withSavedDNS(_ snapshot: LocalSnapshot, _ dns: [String]) -> LocalSnapshot {
        var copy = snapshot
        if var service = copy.primaryService.value {
            service = PrimaryServiceInfo(serviceID: service.serviceID, name: service.name,
                                         interfaceName: service.interfaceName, savedDNS: dns, stateDNS: service.stateDNS)
            copy.primaryService = .collected(service)
        }
        return copy
    }

    /// 替换主服务名称与接口（用于有线网络场景）。
    static func withService(_ snapshot: LocalSnapshot, name: String?, interface: String?) -> LocalSnapshot {
        var copy = snapshot
        if let service = copy.primaryService.value {
            copy.primaryService = .collected(PrimaryServiceInfo(
                serviceID: service.serviceID, name: name, interfaceName: interface,
                savedDNS: service.savedDNS, stateDNS: service.stateDNS))
        }
        return copy
    }

    /// 去掉指定接口。
    static func withoutInterface(_ snapshot: LocalSnapshot, _ name: String) -> LocalSnapshot {
        var copy = snapshot
        copy.interfaces = .collected((snapshot.interfaces.value ?? []).filter { $0.name != name })
        return copy
    }

    /// 追加进程。
    static func addingProcess(_ snapshot: LocalSnapshot, _ entry: ProcessEntry) -> LocalSnapshot {
        var copy = snapshot
        copy.processes = .collected((snapshot.processes.value ?? []) + [entry])
        return copy
    }

    /// 去掉 VPN OpenVPN 进程。
    static func withoutVPNProcess(_ snapshot: LocalSnapshot) -> LocalSnapshot {
        var copy = snapshot
        let executables = Set(vpnExecutables)
        copy.processes = .collected((snapshot.processes.value ?? []).filter {
            !executables.contains($0.executablePath ?? "")
        })
        return copy
    }

    /// VPN OpenVPN 进程（用户目录下的实测路径）。
    static var vpnProcess: ProcessEntry {
        ProcessEntry(pid: 7297, executablePath: vpnExecutables[0])
    }
}
