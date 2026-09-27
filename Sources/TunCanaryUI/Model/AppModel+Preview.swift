import Foundation
import TunCanaryCore

/// 预览状态：用 Core 类型直接构造，供离屏渲染、测试和开发时查看。
public enum PreviewScenario: String, Sendable, CaseIterable {
    /// 全绿：VPN 断开、TUN 运行、DNS 符合预期、站点可达。
    case allGreen
    /// 黄：Google 连续两轮失败。
    case googleWarning
    /// 红：VPN 断开后 DNS 未恢复。
    case dnsCritical
    /// 首次启动：尚无结果，灰色。
    case firstLaunch
    /// 检查进行中：保留上次的黄色，叠加进行中指示。
    case checking
    /// 宽限期：网络切换中。
    case gracePeriod
    /// 内网站点未配置。
    case intranetNotConfigured
    /// VPN 已连接（连接期），内网站点参与探测。
    case vpnConnected

    public var title: String {
        switch self {
        case .allGreen: return "全绿"
        case .googleWarning: return "黄（Google 两轮失败）"
        case .dnsCritical: return "红（DNS 未恢复）"
        case .firstLaunch: return "首次启动"
        case .checking: return "检查进行中"
        case .gracePeriod: return "宽限期（切换中）"
        case .intranetNotConfigured: return "内网未配置"
        case .vpnConnected: return "VPN 已连接"
        }
    }
}

extension AppModel {
    /// 构造示例状态的视图模型。动作全部为空操作。
    public static func preview(_ scenario: PreviewScenario, actions: AppActions = AppActions()) -> AppModel {
        let data = PreviewData.self
        let settings = scenario == .intranetNotConfigured ? AppSettings(expectedDNS: ["119.29.29.29"]) : data.settings
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
            model.intranetDecision = .vpnDisconnected
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
        case .vpnConnected:
            let local = data.connectedLocal()
            model.apply(local: local, connectivityFaults: [], checkedAt: data.now.addingTimeInterval(-20))
            var history = data.history(google: .healthy)
            let intranet = SiteCatalog.intranet(url: settings.intranetURL!)
            for (index, ms) in [31.0, 28, 30, 27, 29].enumerated() {
                history.record(data.result(intranet, .reachable, ms: ms, at: data.round(index)))
            }
            model.siteHistory = history
            model.intranetDecision = SiteCatalog.intranetDecision(intranetURL: settings.intranetURL,
                                                                  vpnState: local.vpnState)
        }
        return model
    }
}

/// 预览数据（合成值）。
enum PreviewData {
    /// 2026-09-26 12:00:00 UTC。
    static let now = Date(timeIntervalSince1970: 1_790_424_000)
    static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    static let settings = AppSettings(intranetURL: URL(string: "https://intranet.corp.example/health"),
                                      expectedDNS: ["119.29.29.29"],
                                      checkPages: [CheckPage(name: "出口检测", url: URL(string: "https://check.example.test/ip")!),
                                                   CheckPage(name: "DNS 检测", url: URL(string: "https://check.example.test/dns")!)])

    /// 红色场景的最近事件：启动后 Google 短暂失败又消失，随后 DNS 未恢复。
    static func dnsCriticalEvents() -> [FaultEvent] {
        let google = "Google 连续两轮访问失败"
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
            diagnosticNotes: ["其他隧道 utun4（100.101.102.103，疑似 Tailscale），不参与判定"],
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
            dnsCard(.ok, "DNS 为 VPN 下发的 DNS（连接期状态）", hint: "连接期状态；启用内网站点探测",
                    evidence: ["保存值：10.20.0.53", "VPN DNS：10.20.0.53"]),
            mihomoCard,
        ], vpn: .connected)
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
