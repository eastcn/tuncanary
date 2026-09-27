import Combine
import Foundation
import TunCanaryCore
import os

/// 界面的唯一数据源。调度器写入检查结果，界面只读取它、通过它发出动作。
@MainActor
public final class AppModel: ObservableObject {
    // MARK: 检查结果（由调度器写入）

    /// 总体状态。检查进行中保留上一轮的值，菜单栏图标因此保留上次的颜色。
    @Published public var overall: OverallAssessment
    /// 本机评估；首次启动、尚无结果时为 nil。
    @Published public var local: LocalAssessment?
    /// 各站点最近 5 次结果（只在内存中）。
    @Published public var siteHistory: SiteHistory
    /// VPN 站点探测决策。
    @Published public var intranetDecision: IntranetProbeDecision
    /// Tailnet 子网探测决策。
    @Published public var tailnetDecision: TailnetProbeDecision
    /// 最近一次完成检查的时间。
    @Published public var lastCheckedAt: Date?
    /// 检查进度；nil 表示空闲。
    @Published public var checkProgress: CheckProgress?
    /// 宽限期结束时间；不在宽限期内为 nil。
    @Published public var graceEndsAt: Date?
    /// 最近的故障事件（旧 → 新），最多 `recentEventLimit` 条。
    @Published public var recentEvents: [FaultEvent] = []
    /// 内存中保留、诊断摘要附带的最近事件条数。
    public static let recentEventLimit = 20

    /// 按需出口检测，仅存内存，不参与总体健康判断或诊断导出。
    @Published public internal(set) var egressResults: [EgressIPResult] = []
    @Published public internal(set) var isCheckingEgress = false
    public var egressChecker: (any EgressIPChecking)?
    var egressTask: Task<Void, Never>?
    var egressGeneration = 0

    // MARK: 设置与系统状态

    /// 已保存的设置。
    @Published public var settings: AppSettings
    /// 通知授权状态。
    @Published public var notificationAuthorization: NotificationAuthorization
    /// 系统通知是否可用（运行在 `.app` 包内）。
    @Published public var notificationsAvailable: Bool
    /// 登录时启动的系统实际状态。
    @Published public var loginItemStatus: LoginItemStatus
    /// 最近一次开关登录项失败的原因。
    @Published public var loginItemError: String?
    /// 当前加载的 VPN 适配器与无效配置说明（由调度器写入）。
    @Published public var adapterSet = VPNAdapterSet()

    // MARK: 界面状态

    @Published public var route: PopoverRoute
    /// 已展开证据的状态卡。
    @Published public var expandedCards: Set<StatusCardKind>
    /// “最近事件”区块是否展开。
    @Published public var showsRecentEvents = false
    /// 设置页草稿。
    @Published public var settingsDraft: SettingsDraft
    /// 刚复制的内容（用于短暂显示“已复制”）：`diagnostics` 或 `command`。
    @Published public private(set) var copiedItem: CopiedItem?
    /// 设置刚保存（短暂显示“已保存”）。
    @Published public private(set) var showsSavedFeedback = false

    /// 可复制的内容。
    public enum CopiedItem: String, Sendable, Equatable {
        case diagnostics
        case command
    }

    /// 注入的动作。
    public var actions: AppActions
    /// 当前时间（预览与测试可固定）。
    public var now: () -> Date
    /// 显示时间用的时区。
    public var timeZone: TimeZone
    /// “已复制”“已保存”提示的显示时长（秒）。
    public var feedbackDuration: TimeInterval = 1.8

    private var copiedToken = 0
    private var savedToken = 0

    public init(
        settings: AppSettings = AppSettings(),
        actions: AppActions = AppActions(),
        overall: OverallAssessment = OverallAssessment(local: nil, connectivityFaults: []),
        local: LocalAssessment? = nil,
        siteHistory: SiteHistory = SiteHistory(),
        intranetDecision: IntranetProbeDecision? = nil,
        tailnetDecision: TailnetProbeDecision? = nil,
        lastCheckedAt: Date? = nil,
        checkProgress: CheckProgress? = nil,
        graceEndsAt: Date? = nil,
        notificationAuthorization: NotificationAuthorization = .notDetermined,
        notificationsAvailable: Bool = false,
        loginItemStatus: LoginItemStatus = .unavailable,
        now: @escaping () -> Date = Date.init,
        timeZone: TimeZone = .current,
        egressChecker: (any EgressIPChecking)? = nil
    ) {
        self.egressChecker = egressChecker
        self.settings = settings
        self.actions = actions
        self.overall = overall
        self.local = local
        self.siteHistory = siteHistory
        self.intranetDecision = intranetDecision
            ?? SiteCatalog.intranetDecision(intranetURL: settings.intranetURL, vpnState: local?.vpnState ?? .unconfirmed)
        self.tailnetDecision = tailnetDecision ?? local?.tailnetDecision ?? .notConfigured
        self.lastCheckedAt = lastCheckedAt
        self.checkProgress = checkProgress
        self.graceEndsAt = graceEndsAt
        self.notificationAuthorization = notificationAuthorization
        self.notificationsAvailable = notificationsAvailable
        self.loginItemStatus = loginItemStatus
        self.now = now
        self.timeZone = timeZone
        route = .main
        expandedCards = []
        settingsDraft = SettingsDraft(settings: settings)
    }

    // MARK: 写入检查结果

    /// 一轮检查完成后更新：重算总体状态，记录完成时间。站点历史和 VPN 站点决策由调用方另行写入。
    public func apply(local: LocalAssessment?, connectivityFaults: [ConnectivityFault], checkedAt: Date) {
        self.local = local
        overall = OverallAssessment(local: local, connectivityFaults: connectivityFaults)
        lastCheckedAt = checkedAt
    }

    // MARK: 派生状态

    public var isChecking: Bool { checkProgress != nil }
    /// 检查进行中时禁用“立即复测”。
    public var canRecheck: Bool { !isChecking }

    public var menuBarIconState: MenuBarIconState {
        MenuBarIconState(overall: overall, isChecking: isChecking)
    }

    public var header: HeaderPresentation {
        PopoverFormatter.header(overall: overall, lastCheckedAt: lastCheckedAt, graceEndsAt: graceEndsAt,
                                isChecking: isChecking, now: now(), timeZone: timeZone)
    }

    public var cards: [StatusCard] {
        PopoverFormatter.cards(local)
    }

    public var siteGroups: [SiteGroupPresentation] {
        PopoverFormatter.siteGroups(history: siteHistory, intranet: intranetDecision, tailnet: tailnetDecision,
                                    redactor: redactor, sites: settings.enabledSites)
    }

    public var recoverySteps: [String] {
        RecoveryGuide.steps(serviceName: local?.primaryServiceName,
                            expectedDNS: settings.disconnectedDNSRule == .equals ? settings.effectiveExpectedDNS : [],
                            proxy: settings.proxySource)
    }

    /// 脱敏器：去掉主目录和 VPN 站点 URL。
    public var redactor: Redactor {
        Redactor(homeDirectory: NSHomeDirectory(), intranetURL: settings.intranetURL,
                 siteURLs: settings.sites.map(\.url))
    }

    /// 是否存在 DNS 未恢复的故障（弹窗中突出“手动恢复步骤”）。
    public var suggestsRecovery: Bool {
        overall.faultKeys.contains(.dnsNotRestored)
    }

    // MARK: 动作

    /// 设置页“用当前值作为预期”：只在系统解析确认经过代理时可用。
    public var learnableExpectedDNS: [String]? {
        local?.learnableExpectedDNS
    }

    /// 把当前保存的 DNS 填入草稿，规则改为“指定地址”。保存前不生效。
    public func adoptCurrentDNSAsExpected() {
        guard let dns = learnableExpectedDNS else { return }
        settingsDraft.disconnectedDNSRule = .equals
        settingsDraft.expectedDNS = dns.joined(separator: ", ")
    }

    public func recheck() {
        guard canRecheck else { return }
        actions.recheck()
    }

    public func toggleEvidence(_ kind: StatusCardKind) {
        if expandedCards.contains(kind) {
            expandedCards.remove(kind)
        } else {
            expandedCards.insert(kind)
        }
    }

    public func showMain() {
        route = .main
    }

    /// 立即重新读取 VPN 适配器目录（不随“保存”）。
    public func reloadAdapters() {
        actions.reloadAdapters()
    }

    public func toggleRecentEvents() {
        showsRecentEvents.toggle()
    }

    public func openRecovery() {
        route = .recovery
    }

    /// 打开设置页：用已保存的设置重置草稿，并刷新通知与登录项状态。
    public func openSettings() {
        Logger(subsystem: AppIdentity.bundleID, category: "interface").debug("settings.open")
        settingsDraft = SettingsDraft(settings: settings)
        loginItemError = nil
        showsSavedFeedback = false
        route = .settings
        Task { await refreshSystemStatus() }
    }

    /// 弹窗关闭后回到主页。
    public func popoverDidClose() {
        route = .main
    }

    /// 草稿的校验结果。
    public var settingsValidation: SettingsDraft.Validation {
        settingsDraft.validate()
    }

    /// 草稿通过校验且有改动时可以保存。
    public var canSaveSettings: Bool {
        settingsValidation.isValid && settingsDraft.hasChanges(comparedTo: settings)
    }

    /// 保存设置：校验通过后更新 `settings`、按新设置重算 VPN 站点决策，并调用注入的保存动作。
    @discardableResult
    public func saveSettings() -> Bool {
        guard let validated = settingsValidation.settings else { return false }
        settings = validated
        settingsDraft = SettingsDraft(settings: validated)
        intranetDecision = SiteCatalog.intranetDecision(intranetURL: validated.intranetURL,
                                                        vpnState: local?.vpnState ?? .unconfirmed)
        // 目标改变后，等下一轮本机检查重新判断路由。
        tailnetDecision = validated.tailnetTarget == nil ? .notConfigured : .unconfirmed
        actions.saveSettings(validated)
        showSavedFeedback()
        return true
    }

    /// 开关登录时启动，状态以系统返回为准。
    public func setLoginItemEnabled(_ enabled: Bool) {
        do {
            loginItemStatus = try actions.setLoginItemEnabled(enabled)
            loginItemError = nil
        } catch let error as LoginItemControlError {
            loginItemError = error.message
            loginItemStatus = actions.loginItemStatus()
        } catch {
            loginItemError = LoginItemControlError.failed(error.localizedDescription).message
            loginItemStatus = actions.loginItemStatus()
        }
    }

    public func openLoginItemSettings() {
        actions.openLoginItemSettings()
    }

    public func requestNotificationPermission() async {
        notificationAuthorization = await actions.requestNotificationAuthorization()
    }

    public func openNotificationSettings() {
        actions.openNotificationSettings()
    }

    /// 刷新通知授权与登录项状态（打开弹窗或设置页时调用）。
    public func refreshSystemStatus() async {
        notificationsAvailable = actions.notificationsAvailable()
        loginItemStatus = actions.loginItemStatus()
        notificationAuthorization = await actions.notificationAuthorization()
    }

    /// 复制脱敏诊断摘要，并短暂显示“已复制”。
    public func copyDiagnostics() {
        actions.copyToPasteboard(actions.diagnosticText(self))
        showCopied(.diagnostics)
    }

    /// 复制一段文本（恢复步骤中的命令）。
    public func copyCommand(_ text: String) {
        actions.copyToPasteboard(text)
        showCopied(.command)
    }

    public func open(_ url: URL) {
        actions.openURL(url)
    }

    public func quit() {
        cancelEgressIP()
        actions.quit()
    }

    // MARK: 诊断摘要

    /// 由当前状态构造诊断摘要。VPN 站点只标注已配置与否，正文在渲染时整体脱敏。
    public func diagnosticSummary(generatedAt: Date, appVersion: String, osVersion: String) -> DiagnosticSummary {
        var entries = DiagnosticSummary.siteEntries(history: siteHistory, sites: settings.enabledSites)
        if let site = intranetDecision.site {
            entries.append(DiagnosticSummary.SiteEntry(site: site, history: siteHistory.recent(for: site.id)))
        }
        if let site = tailnetDecision.site {
            entries.append(DiagnosticSummary.SiteEntry(site: site, history: siteHistory.recent(for: site.id)))
        }
        return DiagnosticSummary(
            generatedAt: generatedAt,
            appVersion: appVersion,
            osVersion: osVersion,
            overall: overall,
            local: local,
            sites: entries,
            intranetConfigured: settings.isIntranetConfigured,
            intranetSkippedText: intranetDecision.skippedText,
            tailnetConfigured: settings.tailnetTarget != nil,
            tailnetSkippedText: tailnetDecision.skippedText,
            events: recentEvents)
    }

    /// 默认的诊断摘要文本：应用版本取 Info.plist（不在应用包内运行时取 `AppIdentity.version`），
    /// 系统版本取 ProcessInfo，全文经过 `redactor`。
    public static func defaultDiagnosticText(_ model: AppModel) -> String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String).map { v in
            (info?["CFBundleVersion"] as? String).map { "\(v)（\($0)）" } ?? v
        } ?? "\(AppIdentity.version)（开发版）"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osText = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return model.diagnosticSummary(generatedAt: model.now(), appVersion: version, osVersion: osText)
            .render(redactor: model.redactor, timeZone: model.timeZone)
    }

    // MARK: 提示

    private func showCopied(_ item: CopiedItem) {
        copiedToken += 1
        let token = copiedToken
        copiedItem = item
        let duration = feedbackDuration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, self.copiedToken == token else { return }
            self.copiedItem = nil
        }
    }

    private func showSavedFeedback() {
        savedToken += 1
        let token = savedToken
        showsSavedFeedback = true
        let duration = feedbackDuration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, self.savedToken == token else { return }
            self.showsSavedFeedback = false
        }
    }
}
