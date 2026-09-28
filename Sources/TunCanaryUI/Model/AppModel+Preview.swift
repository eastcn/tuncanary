import Foundation
import TunCanaryCore

/// 预览状态：用 Core 类型直接构造，供离屏渲染、测试和开发时查看。
public enum PreviewScenario: String, Sendable, CaseIterable {
    /// 全绿：VPN 断开、TUN 运行、DNS 符合预期、站点可达。
    case allGreen
    /// 黄：Google 连续三轮失败。
    case googleWarning
    /// 红：VPN 断开后 DNS 未恢复。
    case dnsCritical
    /// 首次启动：尚无结果，灰色。
    case firstLaunch
    /// 检查进行中：保留上次的黄色，叠加进行中指示。
    case checking
    /// 宽限期：网络切换中。
    case gracePeriod
    /// VPN 站点未配置。
    case intranetNotConfigured
    /// VPN 已连接（连接期），VPN 站点参与探测。
    case vpnConnected
    /// VPN 已连接，连接期由代理接管，DNS 守护进程已安装并写入成功。
    case proxyTakeover

    public var title: String {
        switch self {
        case .allGreen: return "全绿"
        case .googleWarning: return "黄（Google 三轮失败）"
        case .dnsCritical: return "红（DNS 未恢复）"
        case .firstLaunch: return "首次启动"
        case .checking: return "检查进行中"
        case .gracePeriod: return "宽限期（切换中）"
        case .intranetNotConfigured: return "VPN 站点未配置"
        case .vpnConnected: return "VPN 已连接"
        case .proxyTakeover: return "连接期由代理接管"
        }
    }
}

extension AppModel {
    /// 构造示例状态的视图模型。动作全部为空操作。
    public static func preview(_ scenario: PreviewScenario, actions: AppActions = AppActions()) -> AppModel {
        let data = PreviewData.self
        var settings = scenario == .intranetNotConfigured ? AppSettings(expectedDNS: ["119.29.29.29"]) : data.settings
        if scenario == .proxyTakeover { settings.connectedDNSRule = .proxyTakeover }
        if scenario == .googleWarning {
            settings.proxyDiagnosticsEnabled = true
            settings.egressTargets = PreviewData.egressTargets
        }
        let model = AppModel(
            settings: settings,
            actions: actions,
            notificationAuthorization: .authorized,
            notificationsAvailable: true,
            loginItemStatus: .disabled,
            now: { data.now },
            timeZone: data.timeZone)

        switch scenario {
        case .allGreen, .intranetNotConfigured:
            let local = data.greenLocal()
            model.apply(local: local, connectivityFaults: [], checkedAt: data.now.addingTimeInterval(-12))
            model.siteHistory = data.history(google: .healthy)
            model.intranetDecision = SiteCatalog.intranetDecision(intranetURL: settings.intranetURL,
                                                                  vpnState: local.vpnState)
        case .googleWarning, .checking:
            let local = data.greenLocal()
            let faults = ConnectivityTracker.faults(failingSiteIDs: [SiteCatalog.google.id], context: .consecutiveRounds)
            model.apply(local: local, connectivityFaults: faults, checkedAt: data.now.addingTimeInterval(-35))
            model.siteHistory = data.history(google: .failingTwice)
            model.egressResults = data.egressResults()
            model.intranetDecision = .vpnDisconnected
            if scenario == .googleWarning {
                let connection = ProxyLogConnection(
                    network: "TCP", source: "198.18.0.1", process: "TunCanary", host: "www.google.com", port: 443,
                    rule: "DomainSuffix(google.com)", chain: "节点选择[示例节点 HK 01]", error: "connect failed: i/o timeout")
                model.siteDiagnoses[SiteCatalog.google.id] = SiteDiagnosis(
                    siteID: SiteCatalog.google.id, siteName: "Google", diagnosedAt: data.now.addingTimeInterval(-30),
                    manual: false, outcome: .failure(.timeout, detail: "请求超时，错误码 -1001"),
                    route: .proxied(connection, viaTun: true), nodeDelay: .failed(reason: "超时"))
            }
            if scenario == .checking {
                model.checkProgress = CheckProgress(kind: .full, completed: 4, total: 9)
            }
        case .dnsCritical:
            let local = data.dnsCriticalLocal()
            model.apply(local: local, connectivityFaults: [], checkedAt: data.now.addingTimeInterval(-5))
            model.siteHistory = data.history(google: .healthy)
            model.intranetDecision = .vpnDisconnected
            model.expandedCards = [.primaryDNS]
            model.recentEvents = data.dnsCriticalEvents()
            model.showsRecentEvents = true
        case .firstLaunch:
            model.intranetDecision = .vpnUnconfirmed
        case .gracePeriod:
            let local = data.graceLocal()
            model.apply(local: local, connectivityFaults: [], checkedAt: data.now.addingTimeInterval(-2))
            model.siteHistory = data.history(google: .healthy)
            model.intranetDecision = .vpnUnconfirmed
            model.graceEndsAt = data.now.addingTimeInterval(8)
        case .vpnConnected, .proxyTakeover:
            let local = scenario == .proxyTakeover ? data.takeoverLocal() : data.connectedLocal()
            model.apply(local: local, connectivityFaults: [], checkedAt: data.now.addingTimeInterval(-20))
            var history = data.history(google: .healthy)
            let intranet = SiteCatalog.intranet(url: settings.intranetURL!)
            for (index, ms) in [31.0, 28, 30, 27, 29].enumerated() {
                history.record(data.result(intranet, .reachable, ms: ms, at: data.round(index)))
            }
            model.siteHistory = history
            model.intranetDecision = SiteCatalog.intranetDecision(intranetURL: settings.intranetURL,
                                                                  vpnState: local.vpnState)
            if scenario == .proxyTakeover { model.expandedCards = [.primaryDNS] }
        }
        for offset in [-300.0, 0.0] {
            for result in model.egressResults {
                let country = result.location.map { String($0.prefix(2)) }
                let geo = result.ip.flatMap { ip in country.map { EgressGeo(ip: ip, countryCode: $0, checkedAt: result.checkedAt) } }
                let observation = EgressIPResult(target: result.target, checkedAt: result.checkedAt.addingTimeInterval(offset),
                                                ip: result.ip, ipVersion: result.ipVersion, location: result.location, failure: result.failure)
                _ = model.egressState.record(EgressObservation(result: observation, geo: geo), settings: settings.egressMonitoring)
            }
        }
        return model
    }
}

/// 预览数据（合成值）。
enum PreviewData {
    /// 2026-09-26 12:00:00 UTC。
    static let now = Date(timeIntervalSince1970: 1_790_424_000)
    static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    /// 出口检测目标：全部内置项加两个虚构的自定义域名。
    static let egressTargets: [EgressIPTarget] = EgressIPTarget.builtIns +
        ["edge.example.com", "plain.example.org"].compactMap(EgressIPTarget.custom)

    /// 出口检测结果：自定义域名一个成功、一个不经 Cloudflare。
    static func egressResults() -> [EgressIPResult] {
        let at = now.addingTimeInterval(-40)
        return [
            EgressIPResult(target: .cloudflare, checkedAt: at, ip: "2001:db8:85a3::8a2e:370:7334",
                           ipVersion: .ipv6, location: "JP", failure: nil),
            EgressIPResult(target: .claude, checkedAt: at, ip: "203.0.113.24", ipVersion: .ipv4,
                           location: "US", failure: nil),
            EgressIPResult(target: .chatgpt, checkedAt: at, ip: "203.0.113.24", ipVersion: .ipv4,
                           location: "US", failure: nil),
            EgressIPResult(target: .taobao, checkedAt: at, ip: "198.51.100.8", ipVersion: .ipv4,
                           location: "CN · 浙江 杭州", failure: nil),
            EgressIPResult(target: .bytedance, checkedAt: at, ip: "198.51.100.37", ipVersion: .ipv4,
                           location: "SG", failure: nil),
            EgressIPResult(target: egressTargets[5], checkedAt: at, ip: "198.51.100.38", ipVersion: .ipv4, location: "SG", failure: nil),
            EgressIPResult(target: egressTargets[6], checkedAt: at, ip: nil, ipVersion: nil,
                           location: nil, failure: .httpStatus(404)),
        ]
    }

    static let settings = AppSettings(intranetURL: URL(string: "https://intranet.corp.example/health"),
                                      expectedDNS: ["119.29.29.29"],
                                      checkPages: [CheckPage(name: "出口检测", url: URL(string: "https://check.example.test/ip")!),
                                                   CheckPage(name: "DNS 检测", url: URL(string: "https://check.example.test/dns")!)])

    /// 红色场景的最近事件：启动后 Google 短暂失败又消失，随后 DNS 未恢复。
    static func dnsCriticalEvents() -> [FaultEvent] {
        let google = "Google 连续三轮访问失败"
        let dns = "主网络 DNS（Wi-Fi）：VPN 已断开、TUN 运行中，DNS 未恢复为 119.29.29.29"
        return [
            FaultEvent(date: now.addingTimeInterval(-7_200), kind: .started),
            FaultEvent(date: now.addingTimeInterval(-5_400), kind: .appeared, key: .site(SiteCatalog.google.id),
                       severity: .warning, message: google),
            FaultEvent(date: now.addingTimeInterval(-5_160), kind: .cleared, key: .site(SiteCatalog.google.id),
                       severity: .warning, message: google),
            FaultEvent(date: now.addingTimeInterval(-365), kind: .appeared, key: .dnsNotRestored,
                       severity: .critical, message: dns),
        ]
    }

    /// 第 `index` 轮（0 最旧，4 最新）的时间：每 2 分钟一轮轻测。
    static func round(_ index: Int) -> Date {
        now.addingTimeInterval(TimeInterval((index - 4) * 120) - 12)
    }

    // MARK: 状态卡

    static let tunCard = StatusCard(
        kind: .proxyTun, title: "Clash TUN", severity: .ok,
        conclusion: "配置开启，utun1024 存在",
        evidence: [
            "TUN：配置开启（enable_tun_mode=true，tun.enable=true）",
            "utun1024 存在（198.18.0.1，位于 fake-ip 网段 198.18.0.0/16）",
            "verge-mihomo 运行中",
        ])

    static let vpnDisconnectedCard = StatusCard(
        kind: .vpn, title: "Example VPN", severity: .ok, conclusion: "已断开",
        evidence: ["状态文件：已断开", "未发现 VPN 进程", "未发现 VPN 隧道", "VPN DNS（状态文件）：10.20.0.53"])

    static let mihomoCard = StatusCard(
        kind: .proxyDNS, title: "Mihomo DNS", severity: .ok, conclusion: "7874 端口响应 8 ms",
        evidence: ["应答 198.18.0.26（fake-ip，属正常）"])

    static let tailnetCard = StatusCard(
        kind: .tailnet, title: "Tailnet", severity: .ok, conclusion: "已连接（utun4），MagicDNS 正常",
        evidence: [
            "Tailscale 隧道 utun4（100.101.102.103）",
            "tailnet 路由经 utun4",
            "系统解析本机 MagicDNS 名称，返回本机 Tailscale 地址",
        ])

    static func dnsCard(_ severity: Severity, _ conclusion: String, hint: String? = nil,
                        evidence: [String], key: FaultKey? = nil) -> StatusCard {
        StatusCard(kind: .primaryDNS, title: "Wi-Fi DNS", label: "主网络 DNS（Wi-Fi）", severity: severity,
                   conclusion: conclusion, hint: hint, evidence: evidence, faultKey: key)
    }

    static func assessment(_ cards: [StatusCard], vpn: VPNConnectionState, grace: Bool = false) -> LocalAssessment {
        let faults = cards.compactMap { card -> Fault? in
            guard let key = card.faultKey, card.severity.isAlerting else { return nil }
            return Fault(key: key, severity: card.severity, message: card.line, hint: card.hint)
        }
        var local = LocalAssessment(
            severity: Severity.worst(cards.map(\.severity)),
            cards: cards,
            faults: faults,
            primaryReason: "",
            tunState: .running(interface: "utun1024"),
            vpnState: vpn,
            isInGracePeriod: grace,
            intranetProbeEnabled: vpn == .connected,
            primaryServiceName: "Wi-Fi",
            mihomoDNSPort: 7874,
            diagnosticNotes: ["Tailscale 隧道 utun4（100.101.102.103），由 Tailnet 卡检查，不参与 VPN 判定"],
            evaluatedAt: now)
        local.primaryReason = grace ? "网络切换中" : (local.reasons.first?.text ?? "各项检查正常")
        return local
    }

    static func greenLocal() -> LocalAssessment {
        assessment([
            tunCard,
            vpnDisconnectedCard,
            dnsCard(.ok, "DNS 为 119.29.29.29，符合预期",
                    evidence: ["保存值：119.29.29.29", "系统解析 www.google.com 返回 fake-ip 198.18.0.26"]),
            mihomoCard,
            tailnetCard,
        ], vpn: .disconnected)
    }

    static func dnsCriticalLocal() -> LocalAssessment {
        assessment([
            tunCard,
            vpnDisconnectedCard,
            dnsCard(.critical, "VPN 已断开、TUN 运行中，DNS 未恢复为 119.29.29.29",
                    hint: "等待 VPN 完全断开后，关闭并重新开启 Clash TUN",
                    evidence: [
                        "保存值：空（DNS 已被清空）",
                        "生效 DNS：192.168.0.1",
                        "系统解析 www.google.com 返回真实地址 142.250.0.1",
                    ],
                    key: .dnsNotRestored),
            mihomoCard,
            tailnetCard,
        ], vpn: .disconnected)
    }

    static func graceLocal() -> LocalAssessment {
        assessment([
            tunCard,
            StatusCard(kind: .vpn, title: "Example VPN", severity: .unknown, conclusion: "切换中",
                       evidence: ["状态文件：已断开", "未发现 VPN 进程", "未发现 VPN 隧道"]),
            dnsCard(.unknown, "切换中，暂不评估", evidence: ["保存值：空"]),
            mihomoCard,
        ], vpn: .switching, grace: true)
    }

    static func connectedLocal() -> LocalAssessment {
        assessment([
            tunCard,
            StatusCard(kind: .vpn, title: "Example VPN", severity: .ok, conclusion: "已连接",
                       evidence: [
                           "状态文件：已连接",
                           "VPN 进程运行中（pid 4321）",
                           "隧道 utun6 已启用（10.20.30.40，按状态文件中的隧道 IP 识别）",
                           "隧道路由 12 条",
                           "VPN DNS（状态文件）：10.20.0.53",
                       ]),
            dnsCard(.ok, "DNS 为 VPN 下发的 DNS（连接期状态）", hint: "连接期状态；启用 VPN 站点探测",
                    evidence: ["保存值：10.20.0.53", "VPN DNS：10.20.0.53"]),
            mihomoCard,
        ], vpn: .connected)
    }

    /// 连接期由代理接管：守护进程在 VPN 连接后把 DNS 改回预期值。
    static func takeoverLocal() -> LocalAssessment {
        let written = DNSGuardEvent(date: now.addingTimeInterval(-340), phase: .connected, outcome: .written)
        let compliant = DNSGuardEvent(date: now.addingTimeInterval(-25), phase: .connected, outcome: .compliant)
        var dns = dnsCard(.ok, "VPN 已连接，由代理接管：DNS 为 119.29.29.29，符合预期",
                          hint: "连接期由代理接管；启用 VPN 站点探测，VPN 站点失败时先检查代理能否解析 VPN 域名",
                          evidence: ["保存值：119.29.29.29", "系统解析 www.google.com 返回 fake-ip 198.18.0.26"])
        dns.dnsGuard = DNSGuardSummary(
            installed: true, lastRun: compliant, lastWrite: written,
            recentEvents: [
                DNSGuardEvent(date: now.addingTimeInterval(-370), phase: .connected, outcome: .skipped,
                              reason: "代理无法解析 VPN 探针"),
                written, compliant,
            ])
        var local = connectedLocal()
        local.cards[2] = dns
        return local
    }

    // MARK: 站点

    enum GoogleTrend {
        case healthy
        case failingTwice
    }

    static func result(_ site: Site, _ category: ProbeCategory, ms: Double? = nil, status: Int? = nil,
                       attempts: Int = 1, at date: Date) -> SiteResult {
        let outcome: RequestOutcome
        switch category {
        case .reachable, .restricted, .serverError:
            let code = status ?? (category == .reachable ? 200 : category == .restricted ? 403 : 502)
            outcome = .http(status: code, latency: ms.map { $0 / 1000 })
        default:
            outcome = .failure(category)
        }
        let outcomes = Array(repeating: outcome, count: attempts)
        return SiteAggregator.aggregate(site: site, outcomes: outcomes, checkedAt: date)
    }

    static func history(google: GoogleTrend) -> SiteHistory {
        var history = SiteHistory()
        // 关键站点：每 2 分钟一轮轻测，保留 5 次。
        for (index, ms) in [36.0, 33, 41, 35, 34].enumerated() {
            history.record(result(SiteCatalog.baidu, .reachable, ms: ms, at: round(index)))
        }
        for index in 0..<5 {
            let failing = google == .failingTwice && index >= 3
            history.record(failing
                ? result(SiteCatalog.google, .timeout, at: round(index))
                : result(SiteCatalog.google, .reachable, ms: [184.0, 179, 192, 176, 181][index], status: 204, at: round(index)))
        }
        for (index, ms) in [241.0, 236, 252, 238, 244].enumerated() {
            history.record(result(SiteCatalog.claude, .restricted, ms: ms, at: round(index)))
        }
        // 其余站点只在完整检测中出现。
        history.record(result(SiteCatalog.bilibili, .reachable, ms: 44, attempts: 3, at: round(1)))
        history.record(result(SiteCatalog.bilibili, .reachable, ms: 41, attempts: 3, at: round(4)))
        history.record(result(SiteCatalog.jd, .reachable, ms: 39, attempts: 3, at: round(4)))
        history.record(result(SiteCatalog.yahooJapan, .reachable, ms: 156, attempts: 3, at: round(4)))
        history.record(result(SiteCatalog.sony, .reachable, ms: 171, status: 301, attempts: 3, at: round(4)))
        history.record(result(SiteCatalog.github, .reachable, ms: 212, attempts: 3, at: round(1)))
        history.record(result(SiteCatalog.github, .reachable, ms: 204, attempts: 3, at: round(4)))
        history.record(result(SiteCatalog.chatgpt, .restricted, ms: 267, attempts: 3, at: round(4)))
        return history
    }
}
