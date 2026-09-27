import Foundation
import TunCanaryCore
import TunCanarySystem

/// 实机冒烟：采集真实快照，只断言结构合理；评估结果只打印不断言（用户可能随时切换 VPN）。
/// 打印内容全部经过 Core 的 `Redactor` 脱敏；不读取、不打印 Clash secret 或配置原文。
enum LiveSmokeTests {
    static let redactor = Redactor(homeDirectory: NSHomeDirectory())

    static func log(_ text: String) {
        print("    │ " + redactor.redact(text))
    }

    static func milliseconds(_ seconds: TimeInterval) -> String {
        LatencyFormat.milliseconds(seconds)
    }

    static var suite: TestSuite {
        TestSuite("System.Live", [
            TestCase("采集真实快照并评估", timeout: 15) { t in
                let adapters = VPNAdapterStore().load()
                let provider = SystemSnapshotProvider(paths: .currentUser(), adapters: adapters.adapters)
                let report = await provider.collectReport()
                let snapshot = report.snapshot
                printSnapshot(report)

                // 结构断言
                let interfaces = snapshot.interfaces.value ?? []
                t.expect(!interfaces.isEmpty, "应有网络接口")
                t.expect(snapshot.primaryService.isCollected, "应有主网络服务：\(snapshot.primaryService)")
                let processes = snapshot.processes.value ?? []
                t.expect(processes.contains { $0.executableName == KnownPaths.mihomoProcessName },
                         "进程识别应找到 verge-mihomo")
                t.expectEqual(snapshot.mihomoRunning, .collected(true))
                t.expect(snapshot.routes.isCollected, "netstat：\(snapshot.routes)")
                t.expect(snapshot.resolvers.isCollected, "scutil --dns：\(snapshot.resolvers)")
                if let config = snapshot.clashConfig.value, SystemSnapshotProvider.mihomoPort(for: config) != nil {
                    if case .success = snapshot.mihomoDNS {} else {
                        t.fail("Mihomo DNS 应有应答：\(snapshot.mihomoDNS)")
                    }
                } else {
                    t.expect(snapshot.mihomoDNS == .notApplicable || snapshot.mihomoDNS == .notCollected,
                             "TUN 关闭或配置不可读时不查询：\(snapshot.mihomoDNS)")
                    log("注意：Clash 配置不可读或 TUN 关闭，Mihomo DNS 未查询")
                }
                if case .notTested = snapshot.canary { t.fail("系统解析 canary 应已执行") }

                // 评估并打印（不断言颜色）
                let assessment = LocalEvaluator(paths: .currentUser(), adapterSet: adapters)
                    .evaluate(snapshot: snapshot, settings: AppSettings(), inGracePeriod: false)
                log("")
                log("总体：\(assessment.severity.symbol) \(assessment.severity.displayName) — \(assessment.primaryReason)")
                for card in assessment.cards {
                    log("\(card.severity.symbol) [\(card.severity.displayName)] \(card.line)")
                    if let hint = card.hint { log("    提示：\(hint)") }
                    for item in card.evidence { log("    · \(item)") }
                }
                for note in assessment.diagnosticNotes { log("诊断：\(note)") }
            },
            TestCase("连续采集 3 轮的耗时", timeout: 30) { t in
                let provider = SystemSnapshotProvider()
                var durations: [TimeInterval] = []
                for _ in 0..<3 {
                    let report = await provider.collectReport()
                    durations.append(report.totalDuration)
                    let slowest = report.itemDurations.max { $0.value < $1.value }
                    log("本轮 \(milliseconds(report.totalDuration))，最慢 \(slowest?.key.rawValue ?? "-") \(milliseconds(slowest?.value ?? 0))")
                }
                // 超时上限：命令 3 秒 + 回收余量。正常情况下远小于 1 秒，这里只防止挂死。
                for duration in durations {
                    t.expect(duration < 4, "单轮耗时 \(duration) 秒")
                }
            },
            TestCase("网络变化监听安装真实事件源", timeout: 10) { t in
                let observer = SystemNetworkChangeObserver()
                observer.start { event in
                    log("收到事件：\(event.reason.rawValue)")
                }
                t.expectEqual(observer.activeSources, .all)
                observer.stop()
                t.expectEqual(observer.activeSources, [])
            },
        ])
    }

    static func printSnapshot(_ report: SnapshotCollectionReport) {
        let snapshot = report.snapshot
        let items = SnapshotItem.allCases.map { item in
            "\(item.rawValue) \(milliseconds(report.itemDurations[item] ?? 0))"
        }.joined(separator: "，")
        log("采集耗时 \(milliseconds(report.totalDuration))（\(items)）")

        switch snapshot.clashConfig {
        case .collected(let config):
            let tun = config.tunConfigured.map { $0 ? "开启" : "关闭" } ?? "未知"
            let port = config.dnsListenPort.map(String.init) ?? "无"
            log("Clash 配置：TUN \(tun)，设备 \(config.tunDevice ?? "-")，DNS 端口 \(port)，"
                + "\(config.dnsEnhancedMode ?? "-")，fake-ip \(config.fakeIPRange?.description ?? "-")")
        case .failed(let reason):
            log("Clash 配置：读取失败（\(reason)）")
        case .notCollected:
            log("Clash 配置：未采集")
        }

        if let processes = snapshot.processes.value {
            let text = processes.map { "\($0.executableName ?? "?")(pid \($0.pid))：\($0.executablePath ?? "-")" }
            log("相关进程：" + (text.isEmpty ? "无" : text.joined(separator: "；")))
        } else {
            log("相关进程：\(snapshot.processes)")
        }

        if let interfaces = snapshot.interfaces.value {
            let shown = interfaces.filter { !$0.ipv4Addresses.isEmpty || $0.isTunnel }.map { iface in
                let ips = iface.ipv4Addresses.map(\.description).joined(separator: ",")
                return "\(iface.name)\(iface.isUp ? "↑" : "↓")\(ips.isEmpty ? "" : " " + ips)"
            }
            log("接口（\(interfaces.count) 个，列出有 IPv4 或 utun 的）：" + shown.joined(separator: "；"))
        }

        if let routes = snapshot.routes.value {
            let perInterface = Dictionary(grouping: routes, by: \.interfaceName).mapValues(\.count)
            let tunnels = perInterface.filter { $0.key.hasPrefix("utun") }.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value) 条" }.joined(separator: "，")
            log("路由 \(routes.count) 条；utun：\(tunnels.isEmpty ? "无" : tunnels)")
        } else {
            log("路由：\(snapshot.routes)")
        }

        if let resolvers = snapshot.resolvers.value {
            log("解析器 \(resolvers.count) 个（scoped \(resolvers.filter(\.isScoped).count) 个）")
        } else {
            log("解析器：\(snapshot.resolvers)")
        }

        switch snapshot.primaryService {
        case .collected(let service):
            log("主服务：\(service.name ?? "?")（\(service.interfaceName ?? "?")），保存 DNS \(DNSList.display(service.savedDNS))，"
                + "State DNS \(DNSList.display(service.stateDNS))")
        case .failed(let reason):
            log("主服务：失败（\(reason)）")
        case .notCollected:
            log("主服务：未采集")
        }
        log("全局 DNS：" + (snapshot.globalDNS.value.map(DNSList.display) ?? "\(snapshot.globalDNS)"))

        for (id, state) in snapshot.vpnStatusFiles.sorted(by: { $0.key < $1.key }) {
            switch state {
            case .present(let status):
                log("VPN 状态文件 \(id)：status=\(status.status.map(String.init) ?? "-")，"
                    + "connecting=\(status.connecting.map(String.init) ?? "-")，"
                    + "tunnelIP=\(status.tunnelIP ?? "-")，DNS=\(DNSList.display(status.dnsServers))")
            case .missing:
                log("VPN 状态文件 \(id)：不存在")
            case .unreadable(let reason):
                log("VPN 状态文件 \(id)：不可读（\(reason)）")
            case .notCollected:
                log("VPN 状态文件 \(id)：未采集")
            }
        }

        switch snapshot.mihomoDNS {
        case .success(let port, let latency, let answers):
            log("Mihomo DNS：\(port) 端口响应 \(milliseconds(latency))，应答 \(answers.map(\.description).joined(separator: ", "))")
        case .noResponse(let port):
            log("Mihomo DNS：\(port) 端口无响应")
        case .notApplicable:
            log("Mihomo DNS：不适用")
        case .notCollected:
            log("Mihomo DNS：未采集")
        }

        switch snapshot.canary {
        case .resolved(let addresses):
            log("系统解析 \(PulseConstants.canaryHost)：\(addresses.map(\.description).joined(separator: ", "))")
        case .failed(let reason):
            log("系统解析 \(PulseConstants.canaryHost)：失败（\(reason)）")
        case .notTested:
            log("系统解析：未执行")
        }

        switch snapshot.canaryIPv6 {
        case .resolved(let addresses):
            log("系统解析 \(PulseConstants.canaryHost) AAAA：\(addresses.map(\.description).joined(separator: ", "))")
        case .noRecord:
            log("系统解析 \(PulseConstants.canaryHost) AAAA：无记录")
        case .failed(let reason):
            log("系统解析 \(PulseConstants.canaryHost) AAAA：失败（\(reason)）")
        case .notTested:
            log("系统解析 AAAA：未执行")
        }
    }
}
