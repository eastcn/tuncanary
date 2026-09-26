import Foundation
import TunCanaryCore
import TunCanaryUI
import SwiftUI

/// 视图模型：预览状态、注入动作、设置草稿校验与保存、复制诊断摘要。
enum UIAppModelTests {
    /// 记录动作调用的桩。
    @MainActor
    final class ActionLog {
        var rechecks = 0
        var saved: [AppSettings] = []
        var loginRequests: [Bool] = []
        var copied: [String] = []
        var opened: [URL] = []
        var quits = 0
        var notificationRequests = 0
        var loginStatus: LoginItemStatus = .disabled
        var loginError: Error?
        var authorization: NotificationAuthorization = .notDetermined

        var actions: AppActions {
            AppActions(
                recheck: { self.rechecks += 1 },
                saveSettings: { self.saved.append($0) },
                setLoginItemEnabled: { enabled in
                    self.loginRequests.append(enabled)
                    if let error = self.loginError { throw error }
                    self.loginStatus = enabled ? .requiresApproval : .disabled
                    return self.loginStatus
                },
                loginItemStatus: { self.loginStatus },
                requestNotificationAuthorization: {
                    self.notificationRequests += 1
                    self.authorization = .authorized
                    return .authorized
                },
                notificationAuthorization: { self.authorization },
                notificationsAvailable: { true },
                copyToPasteboard: { self.copied.append($0) },
                openURL: { self.opened.append($0) },
                quit: { self.quits += 1 })
        }
    }

    static var suite: TestSuite {
        TestSuite("UI.AppModel", [
            TestCase("预览状态：各场景的总体状态") { t in await previews(t) },
            TestCase("立即复测：检查进行中时不调用") { t in await recheck(t) },
            TestCase("设置草稿：校验错误就近返回") { t in await draftValidation(t) },
            TestCase("设置草稿：频率与站点完整往返") { t in await draftRoundTrip(t) },
            TestCase("设置草稿：拒绝无效频率与站点") { t in await invalidFrequencyAndSites(t) },
            TestCase("L6：分组输入框逐字输入不被映射改写，保存时再映射") { t in await groupFieldTyping(t) },
            TestCase("保存设置：通过校验且有改动才保存") { t in await saveSettings(t) },
            TestCase("DNS 规则：采用当前值后草稿改为指定地址") { t in await adoptCurrentDNS(t) },
            TestCase("代理客户端：手动参数只在手动模式下校验") { t in await manualProxyDraft(t) },
            TestCase("常用站点模板：只列出未加入的，加入后可保存") { t in await siteTemplates(t) },
            TestCase("检测页与出口目标：草稿校验与往返") { t in await checkPagesDraft(t) },
            TestCase("禁用站点：展示与诊断只包含启用站点") { t in await enabledSitePresentation(t) },
            TestCase("登录时启动：状态以系统返回为准，失败时显示原因") { t in await loginItem(t) },
            TestCase("通知权限：申请与刷新") { t in await notifications(t) },
            TestCase("复制诊断摘要：脱敏并短暂显示“已复制”") { t in await copyDiagnostics(t) },
            TestCase("页面切换、证据展开、外部链接与退出") { t in await navigation(t) },
            TestCase("apply：重算总体状态并记录检查时间") { t in await apply(t) },
        ])
    }

    @MainActor
    static func previews(_ t: TestContext) async {
        let expected: [PreviewScenario: (Severity, String)] = [
            .allGreen: (.ok, "正常"),
            .googleWarning: (.warning, "需关注"),
            .dnsCritical: (.critical, "故障"),
            .firstLaunch: (.unknown, "未确认"),
            .checking: (.warning, "需关注"),
            .gracePeriod: (.unknown, "切换中"),
            .intranetNotConfigured: (.ok, "正常"),
            .vpnConnected: (.ok, "正常"),
        ]
        for scenario in PreviewScenario.allCases {
            let model = AppModel.preview(scenario)
            guard let (severity, text) = expected[scenario] else {
                t.fail("缺少场景 \(scenario.rawValue) 的期望值")
                continue
            }
            t.expectEqual(model.overall.severity, severity, scenario.rawValue)
            t.expectEqual(model.header.statusText, text, scenario.rawValue)
            t.expectEqual(model.menuBarIconState.severity, severity, scenario.rawValue)
            t.expectEqual(model.cards.count, 4, scenario.rawValue)
            t.expectEqual(model.siteGroups.count, 3, scenario.rawValue)
        }

        let google = AppModel.preview(.googleWarning)
        t.expectEqual(google.overall.primaryReason, "Google 连续两轮访问失败")
        let googleRow = google.siteGroups[1].rows.first { $0.id == "google" }
        t.expectEqual(googleRow?.statusText, "超时")
        t.expectEqual(googleRow?.detailText, "连续 2 次失败")
        t.expectEqual(googleRow?.history.map(\.tone), [.ok, .ok, .ok, .critical, .critical])

        let critical = AppModel.preview(.dnsCritical)
        t.expect(critical.suggestsRecovery)
        t.expectEqual(critical.header.hint, "等待 VPN 完全断开后，关闭并重新开启 Clash TUN")
        t.expectEqual(critical.recoverySteps.count, 5)
        t.expectContains(critical.recoverySteps[2], "networksetup -getdnsservers Wi-Fi")

        let first = AppModel.preview(.firstLaunch)
        t.expectNil(first.local)
        t.expectEqual(first.header.reason, "尚无检查结果")
        t.expectEqual(first.header.checkedText, "尚未完成检查")
        t.expect(first.cards.allSatisfy { $0.severity == .unknown })

        let checking = AppModel.preview(.checking)
        t.expect(checking.isChecking)
        t.expect(!checking.canRecheck)
        t.expect(checking.menuBarIconState.isChecking)
        t.expectEqual(checking.menuBarIconState.severity, .warning, "进行中保留上次的颜色")

        let grace = AppModel.preview(.gracePeriod)
        t.expectEqual(grace.header.graceText, "网络切换中，20:00:08 后自动复查")
        t.expectEqual(grace.overall.tooltip, "TunCanary：切换中 — 网络切换中")

        let notConfigured = AppModel.preview(.intranetNotConfigured)
        t.expectEqual(notConfigured.intranetDecision, .notConfigured)
        t.expectEqual(notConfigured.siteGroups[2].rows.first?.statusText, "未验证")

        let connected = AppModel.preview(.vpnConnected)
        t.expectEqual(connected.intranetDecision.site?.id, SiteCatalog.intranetID)
        t.expectEqual(connected.siteGroups[2].rows.first?.statusText, "可达")
        t.expectEqual(AppModel.preview(.allGreen).siteGroups[2].rows.first?.statusText, "未连接 VPN")
    }

    @MainActor
    static func recheck(_ t: TestContext) async {
        let log = ActionLog()
        let model = AppModel.preview(.allGreen, actions: log.actions)
        model.recheck()
        t.expectEqual(log.rechecks, 1)
        model.checkProgress = CheckProgress(kind: .full, completed: 1, total: 9)
        t.expect(!model.canRecheck)
        model.recheck()
        t.expectEqual(log.rechecks, 1, "进行中不重复触发")
        model.checkProgress = nil
        model.recheck()
        t.expectEqual(log.rechecks, 2)
    }

    @MainActor
    static func draftValidation(_ t: TestContext) async {
        var draft = SettingsDraft(settings: AppSettings(
            intranetURL: URL(string: "https://intranet.corp.example/health"),
            expectedDNS: ["119.29.29.29", "223.5.5.5"]))
        t.expectEqual(draft.intranetURL, "https://intranet.corp.example/health")
        t.expectEqual(draft.expectedDNS, "119.29.29.29, 223.5.5.5")
        t.expect(draft.validate().isValid)

        draft.intranetURL = "ftp://intranet.corp.example"
        draft.expectedDNS = "119.29.29.295"
        let invalid = draft.validate()
        t.expect(!invalid.isValid)
        t.expectNil(invalid.settings)
        t.expectEqual(invalid.intranetURLError, "内网站点 URL 必须是 http 或 https")
        t.expectEqual(invalid.expectedDNSError, "“119.29.29.295”不是有效的 IPv4 地址")

        draft.intranetURL = "https://"
        t.expectEqual(draft.validate().intranetURLError, "内网站点 URL 缺少主机名")
        draft.expectedDNS = "  "
        t.expectEqual(draft.validate().expectedDNSError, "预期 DNS 至少填写一个 IPv4 地址")

        let cleared = SettingsDraft(intranetURL: " ", expectedDNS: "119.29.29.29、223.5.5.5",
                                    notificationsEnabled: false)
        let settings = cleared.validate().settings
        t.expectEqual(settings, AppSettings(intranetURL: nil, expectedDNS: ["119.29.29.29", "223.5.5.5"],
                                            notificationsEnabled: false))
    }

    @MainActor
    static func saveSettings(_ t: TestContext) async {
        let log = ActionLog()
        let model = AppModel.preview(.intranetNotConfigured, actions: log.actions)
        model.openSettings()
        t.expectEqual(model.route, .settings)
        t.expect(!model.canSaveSettings, "未改动时不可保存")

        model.settingsDraft.intranetURL = "intranet.corp.example"
        t.expect(!model.canSaveSettings)
        t.expect(!model.saveSettings())
        t.expectEqual(log.saved.count, 0, "校验失败不调用保存动作")

        model.settingsDraft.intranetURL = "https://intranet.corp.example/health"
        model.settingsDraft.notificationsEnabled = false
        t.expect(model.canSaveSettings)
        t.expect(model.saveSettings())
        t.expectEqual(log.saved.count, 1)
        t.expectEqual(log.saved.first?.intranetURL?.absoluteString, "https://intranet.corp.example/health")
        t.expectEqual(log.saved.first?.notificationsEnabled, false)
        t.expectEqual(model.settings, log.saved.first)
        t.expectEqual(model.intranetDecision, .vpnDisconnected, "VPN 断开：已配置但不探测")
        t.expect(model.showsSavedFeedback)
        t.expect(!model.canSaveSettings, "保存后草稿与设置一致")

        // 分隔符与空白不同、规范化后与已保存的值相同：不算改动。
        model.settingsDraft.expectedDNS = " 119.29.29.29、"
        t.expect(!model.canSaveSettings)
        model.settingsDraft.expectedDNS = "119.29.29.29, 223.5.5.5"
        t.expect(model.canSaveSettings)
    }

    @MainActor
    static func adoptCurrentDNS(_ t: TestContext) async {
        let model = AppModel.preview(.allGreen)
        model.settings = AppSettings()
        model.openSettings()
        t.expectNil(model.learnableExpectedDNS, "预览评估没有可采用的值")
        var local = try? t.require(model.local)
        local?.learnableExpectedDNS = ["192.0.2.53", "192.0.2.54"]
        model.apply(local: local, connectivityFaults: [], checkedAt: Date(timeIntervalSince1970: 1_790_424_000))
        t.expectEqual(model.learnableExpectedDNS, ["192.0.2.53", "192.0.2.54"])
        t.expectEqual(model.settingsDraft.disconnectedDNSRule, .notSet)
        model.adoptCurrentDNSAsExpected()
        t.expectEqual(model.settingsDraft.disconnectedDNSRule, .equals)
        t.expectEqual(model.settingsDraft.expectedDNS, "192.0.2.53, 192.0.2.54")
        t.expectEqual(model.settingsValidation.settings?.expectedDNS, ["192.0.2.53", "192.0.2.54"])
        t.expect(model.canSaveSettings)
    }

    @MainActor
    static func checkPagesDraft(_ t: TestContext) async {
        var draft = SettingsDraft(settings: AppSettings())
        t.expectEqual(draft.checkPages, [])
        t.expect(!draft.egressIncludesClaude)
        draft.checkPages.append(SettingsDraft.CheckPageDraft(name: "IP 检测", url: "ftp://check.example.test/"))
        t.expectEqual(draft.validate().checkPageErrors[0], "名称须为 1–20 个字符，URL 须为含主机名的 http 或 https 地址")
        t.expect(!draft.validate().isValid)
        draft.checkPages[0].url = " https://check.example.test/ip "
        draft.egressIncludesClaude = true
        let settings = try? t.require(draft.validate().settings)
        t.expectEqual(settings?.checkPages, [CheckPage(name: "IP 检测", url: URL(string: "https://check.example.test/ip")!)])
        t.expectEqual(settings?.egressTargets, [.claude, .cloudflare])
        let roundTrip = SettingsDraft(settings: settings!)
        t.expectEqual(roundTrip.checkPages.map(\.url), ["https://check.example.test/ip"])
        t.expect(roundTrip.egressIncludesClaude)
    }

    @MainActor
    static func siteTemplates(_ t: TestContext) async {
        var draft = SettingsDraft(settings: AppSettings())
        t.expectEqual(draft.sites.map(\.siteID), ["baidu", "bilibili", "google", "github", "cloudflare"])
        t.expectEqual(draft.availableTemplates.map(\.id), ["jd", "yahooJapan", "sony", "claude", "chatgpt"])
        draft.addTemplate(SiteCatalog.claude)
        draft.addTemplate(SiteCatalog.claude)
        draft.addTemplate(SiteCatalog.baidu)
        t.expectEqual(draft.sites.map(\.siteID).filter { $0 == "claude" }.count, 1, "同一模板只加一次")
        t.expectEqual(draft.sites.count, 6)
        t.expect(!draft.availableTemplates.contains { $0.id == "claude" })
        let saved = try? t.require(draft.validate().settings)
        t.expectEqual(saved?.sites.last, SiteCatalog.claude)
        t.expect(saved?.sites.last?.inLightProbe == false, "模板默认不参与后台检测")
    }

    @MainActor
    static func manualProxyDraft(_ t: TestContext) async {
        var draft = SettingsDraft(settings: AppSettings())
        t.expectEqual(draft.proxyClient, .clashVergeRev)
        t.expectEqual(draft.manualFakeIPRange, "198.18.0.0/15")
        draft.manualDNSPort = "abc"
        t.expect(draft.validate().isValid, "未选手动模式时不校验手动参数")
        t.expectEqual(draft.validate().settings?.manualProxy, ManualProxyConfig(), "不合法的手动参数回落到默认值")

        draft.proxyClient = .manual
        let invalid = draft.validate()
        t.expect(!invalid.isValid)
        t.expectEqual(invalid.manualDNSPortError, "代理 DNS 端口须为 1–65535 的整数，留空表示不检测")
        draft.manualDNSPort = " 1053 "
        draft.manualProcessName = " mihomo "
        let settings = try? t.require(draft.validate().settings)
        t.expectEqual(settings?.proxyClient, .manual)
        t.expectEqual(settings?.manualProxy, ManualProxyConfig(fakeIPRange: "198.18.0.0/15", dnsPort: 1053, coreProcessName: "mihomo"))
        let roundTrip = SettingsDraft(settings: settings!)
        t.expectEqual(roundTrip.manualDNSPort, "1053")
        t.expectEqual(roundTrip.proxyClient, .manual)
    }

    @MainActor
    static func draftRoundTrip(_ t: TestContext) async {
        var custom = Site(id: "custom", name: "自定义", group: .overseas,
                          url: URL(string: "https://custom.example.test/health")!,
                          isKey: true, inLightProbe: true)
        custom.isEnabled = false
        let saved = AppSettings(localCheckInterval: 45, lightProbeInterval: 300, sites: [custom])
        var draft = SettingsDraft(settings: saved)
        t.expectEqual(draft.localCheckInterval, "45")
        t.expectEqual(draft.lightProbeInterval, "300")
        t.expectEqual(draft.sites.count, 1)
        t.expectEqual(draft.sites.first?.siteID, "custom")
        t.expectEqual(draft.sites.first?.isEnabled, false)
        t.expectEqual(draft.validate().settings, saved)
        t.expect(!draft.hasChanges(comparedTo: saved))

        let log = ActionLog()
        let model = AppModel(settings: saved, actions: log.actions)
        model.settingsDraft.notificationsEnabled = false
        t.expect(model.saveSettings())
        t.expectEqual(log.saved.first?.localCheckInterval, 45)
        t.expectEqual(log.saved.first?.lightProbeInterval, 300)
        t.expectEqual(log.saved.first?.sites, [custom])

        // 只改旧字段仍须保留频率和站点；还原默认值仅修改未保存草稿。
        draft.notificationsEnabled = false
        t.expectEqual(draft.validate().settings?.sites, [custom])
        t.expectEqual(draft.validate().settings?.localCheckInterval, 45)
        draft.sites[0].inLightProbe = false
        t.expectEqual(draft.validate().settings?.sites.first?.isKey, false)
        t.expectEqual(draft.validate().settings?.sites.first?.inLightProbe, false)
        draft.restoreDefaultSites()
        t.expectEqual(draft.sites.count, SiteCatalog.defaultSites.count)
        t.expectEqual(saved.sites, [custom])
        draft.sites.removeAll()
        t.expectEqual(draft.validate().settings?.sites, [])
        draft.addSite()
        draft.addSite()
        t.expectEqual(draft.sites.map(\.siteID), ["site-1", "site-2"])
    }

    @MainActor
    static func invalidFrequencyAndSites(_ t: TestContext) async {
        var draft = SettingsDraft(settings: AppSettings())
        draft.localCheckInterval = "4"
        draft.lightProbeInterval = "120.5"
        t.expect(!draft.validate().isValid)
        t.expect(draft.validate().localCheckIntervalError != nil)
        t.expect(draft.validate().lightProbeIntervalError != nil)
        draft.localCheckInterval = "3601"
        draft.lightProbeInterval = "86401"
        t.expect(!draft.validate().isValid)
        draft.localCheckInterval = "20"
        draft.lightProbeInterval = "120"

        draft.sites = [SettingsDraft.SiteDraft(site: SiteCatalog.baidu),
                       SettingsDraft.SiteDraft(site: SiteCatalog.google)]
        draft.sites[1].siteID = draft.sites[0].siteID
        draft.sites[1].name = ""
        draft.sites[1].group = .intranet
        draft.sites[1].url = "https://user:pass@example.test/"
        let invalid = draft.validate()
        t.expect(!invalid.isValid)
        t.expect(invalid.siteErrors[1]?.id != nil)
        t.expect(invalid.siteErrors[1]?.name != nil)
        t.expect(invalid.siteErrors[1]?.group != nil)
        t.expect(invalid.siteErrors[1]?.url != nil)
        draft.sites[1].siteID = "intranet"
        t.expect(draft.validate().siteErrors[1]?.id != nil)
        draft.sites[1] = SettingsDraft.SiteDraft(site: SiteCatalog.google)
        draft.sites[1].group = SiteGroup(rawValue: " 东亚 ")
        t.expectEqual(draft.validate().settings?.sites[1].group, SiteGroup(rawValue: "东亚"))
        draft.sites[1].group = SiteGroup(rawValue: "内网站点")
        t.expect(draft.validate().siteErrors[1]?.group != nil)
        draft.sites = Array(repeating: SettingsDraft.SiteDraft(site: SiteCatalog.baidu), count: 21)
        t.expect(draft.validate().siteCountError != nil)
    }

    @MainActor
    static func groupFieldTyping(_ t: TestContext) async {
        var draft = SettingsDraft(settings: AppSettings(sites: [SiteCatalog.sony]))
        let site = Binding(get: { draft.sites[0] }, set: { draft.sites[0] = $0 })
        let field = SettingsDraft.SiteDraft.groupFieldBinding(site)
        field.wrappedValue = ""
        for character in "japan" {
            let typed = field.wrappedValue + String(character)
            field.wrappedValue = typed
            t.expectEqual(field.wrappedValue, typed, "输入过程中文本不应被改写")
        }
        t.expectEqual(draft.validate().settings?.sites.first?.group, .overseas, "保存时 japan 映射为海外")
        field.wrappedValue = " 东亚 "
        t.expectEqual(field.wrappedValue, " 东亚 ")
        t.expectEqual(draft.validate().settings?.sites.first?.group, SiteGroup(rawValue: "东亚"))
        field.wrappedValue = "国内"
        t.expectEqual(draft.validate().settings?.sites.first?.group, .mainland)
    }

    @MainActor
    static func enabledSitePresentation(_ t: TestContext) async {
        var disabled = SiteCatalog.google
        disabled.isEnabled = false
        let custom = Site(id: "custom", name: "自定义", group: SiteGroup(rawValue: "东亚"),
                          url: URL(string: "https://custom.example.test/")!,
                          isKey: true, inLightProbe: true)
        let model = AppModel(settings: AppSettings(sites: [disabled, custom]))
        t.expectEqual(model.siteGroups.flatMap(\.rows).map(\.id), ["custom", SiteCatalog.intranetID])
        let summary = model.diagnosticSummary(generatedAt: Date(timeIntervalSince1970: 0),
                                              appVersion: "1", osVersion: "13")
        t.expectEqual(summary.sites.map { $0.site.id }, ["custom"])
        model.settings.sites = []
        t.expectEqual(model.siteGroups.map(\.group), [.intranet])
        t.expect(model.diagnosticSummary(generatedAt: Date(timeIntervalSince1970: 0),
                                         appVersion: "1", osVersion: "13").sites.isEmpty)
    }

    @MainActor
    static func loginItem(_ t: TestContext) async {
        let log = ActionLog()
        let model = AppModel.preview(.allGreen, actions: log.actions)
        model.setLoginItemEnabled(true)
        t.expectEqual(log.loginRequests, [true])
        t.expectEqual(model.loginItemStatus, .requiresApproval)
        t.expectNil(model.loginItemError)

        log.loginError = LoginItemControlError.unavailable
        log.loginStatus = .unavailable
        model.setLoginItemEnabled(false)
        t.expectEqual(model.loginItemStatus, .unavailable, "失败后回读系统状态")
        t.expectEqual(model.loginItemError, "登录时启动仅在安装后的应用包中可用")

        struct Other: Error, LocalizedError { var errorDescription: String? { "操作不被允许" } }
        log.loginError = Other()
        model.setLoginItemEnabled(true)
        t.expectEqual(model.loginItemError, "无法更改登录时启动：操作不被允许")
    }

    @MainActor
    static func notifications(_ t: TestContext) async {
        let log = ActionLog()
        let model = AppModel(actions: log.actions)
        t.expectEqual(model.notificationAuthorization, .notDetermined)
        t.expect(!model.notificationsAvailable)
        await model.refreshSystemStatus()
        t.expect(model.notificationsAvailable)
        t.expectEqual(model.loginItemStatus, .disabled)
        await model.requestNotificationPermission()
        t.expectEqual(log.notificationRequests, 1)
        t.expectEqual(model.notificationAuthorization, .authorized)
    }

    @MainActor
    static func copyDiagnostics(_ t: TestContext) async {
        let log = ActionLog()
        let model = AppModel.preview(.vpnConnected, actions: log.actions)
        model.feedbackDuration = 0.05
        model.copyDiagnostics()
        t.expectEqual(log.copied.count, 1)
        let text = log.copied.first ?? ""
        t.expectContains(text, "TunCanary 诊断摘要")
        t.expectContains(text, "总体状态：正常")
        t.expectContains(text, "内网站点：已配置")
        t.expectContains(text, "10.x.x.x")
        t.expectNotContains(text, "intranet.corp.example")
        t.expectNotContains(text, "10.20.0.53")
        t.expectNotContains(text, NSHomeDirectory())
        t.expectEqual(model.copiedItem, .diagnostics)
        try? await Task.sleep(nanoseconds: 300_000_000)
        t.expectNil(model.copiedItem, "提示应在短暂显示后消失")

        // 生成方式可注入。
        var custom = log.actions
        custom.diagnosticText = { _ in "自定义摘要" }
        model.actions = custom
        model.copyDiagnostics()
        t.expectEqual(log.copied.last, "自定义摘要")

        model.copyCommand("networksetup -getdnsservers Wi-Fi")
        t.expectEqual(log.copied.last, "networksetup -getdnsservers Wi-Fi")
        t.expectEqual(model.copiedItem, .command)

        // 诊断摘要的结构：公开站点 + 已探测的内网。
        let summary = model.diagnosticSummary(generatedAt: Date(timeIntervalSince1970: 0), appVersion: "1.0", osVersion: "13.0")
        t.expectEqual(summary.sites.count, SiteCatalog.defaultSites.count + 1)
        t.expect(summary.intranetConfigured)
        t.expectNil(summary.intranetSkippedText)
        let disconnected = AppModel.preview(.allGreen).diagnosticSummary(generatedAt: Date(timeIntervalSince1970: 0),
                                                                         appVersion: "1.0", osVersion: "13.0")
        t.expectEqual(disconnected.sites.count, SiteCatalog.defaultSites.count)
        t.expectEqual(disconnected.intranetSkippedText, "未连接 VPN")
    }

    @MainActor
    static func navigation(_ t: TestContext) async {
        let log = ActionLog()
        let model = AppModel.preview(.dnsCritical, actions: log.actions)
        t.expectEqual(model.expandedCards, [.primaryDNS])
        model.toggleEvidence(.primaryDNS)
        model.toggleEvidence(.proxyTun)
        t.expectEqual(model.expandedCards, [.proxyTun])

        model.openRecovery()
        t.expectEqual(model.route, .recovery)
        model.popoverDidClose()
        t.expectEqual(model.route, .main)

        model.settings.intranetURL = nil
        model.settingsDraft.intranetURL = "残留的输入"
        model.openSettings()
        t.expectEqual(model.settingsDraft.intranetURL, "", "打开设置时用已保存的设置重置草稿")
        model.showMain()
        t.expectEqual(model.route, .main)

        let first = URL(string: "https://check.example.test/ip")!
        let second = URL(string: "https://check.example.test/dns")!
        model.open(first)
        model.open(second)
        t.expectEqual(log.opened, [first, second])
        model.quit()
        t.expectEqual(log.quits, 1)
    }

    @MainActor
    static func apply(_ t: TestContext) async {
        let model = AppModel()
        t.expectEqual(model.overall.severity, .unknown)
        t.expectEqual(model.intranetDecision, .notConfigured)
        let local = UIPresentationTests.greenLocal()
        let checkedAt = Date(timeIntervalSince1970: 1_790_424_000)
        model.apply(local: local,
                    connectivityFaults: ConnectivityTracker.faults(failingSiteIDs: ["baidu"], context: .consecutiveRounds),
                    checkedAt: checkedAt)
        t.expectEqual(model.overall.severity, .critical)
        t.expectEqual(model.overall.primaryReason, "百度连续两轮访问失败，国内出口故障")
        t.expectEqual(model.lastCheckedAt, checkedAt)
        t.expectEqual(model.local, local)
    }
}
