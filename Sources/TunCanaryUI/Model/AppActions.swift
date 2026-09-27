import AppKit
import Foundation
import TunCanaryCore

/// 界面发出的全部动作，由外部（应用入口）注入。默认值全部为空操作，预览和测试不产生副作用；
/// 实际运行时用 `AppActions.live(...)` 接到 SettingsStore、通知器、登录项和系统服务。
public struct AppActions {
    /// 立即复测：执行一次本机检查和全部站点的完整检测。进行中时界面不会调用。
    public var recheck: @MainActor () -> Void
    /// 立即重新读取 VPN 适配器目录，并做一次本机检查。
    public var reloadAdapters: @MainActor () -> Void
    /// 保存设置（已通过 `SettingsValidator` 校验）。实现方负责持久化并按新设置复查。
    public var saveSettings: @MainActor (AppSettings) -> Void
    /// 开关登录时启动，返回操作后的系统实际状态；失败时抛错（错误信息会显示在设置页）。
    public var setLoginItemEnabled: @MainActor (Bool) throws -> LoginItemStatus
    /// 读取登录时启动的系统实际状态。
    public var loginItemStatus: @MainActor () -> LoginItemStatus
    /// 打开“系统设置 → 登录项”。
    public var openLoginItemSettings: @MainActor () -> Void
    /// 申请通知权限，返回申请后的授权状态。
    public var requestNotificationAuthorization: @MainActor () async -> NotificationAuthorization
    /// 读取通知授权状态。
    public var notificationAuthorization: @MainActor () async -> NotificationAuthorization
    /// 系统通知是否可用（运行在 `.app` 包内）。
    public var notificationsAvailable: @MainActor () -> Bool
    /// 打开系统设置中的通知页面。
    public var openNotificationSettings: @MainActor () -> Void
    /// 生成脱敏诊断摘要文本。默认用 `AppModel.defaultDiagnosticText`。
    public var diagnosticText: @MainActor (AppModel) -> String
    /// 写入剪贴板。
    public var copyToPasteboard: @MainActor (String) -> Void
    /// 打开外部链接（检测页）。
    public var openURL: @MainActor (URL) -> Void
    /// 退出应用。
    public var quit: @MainActor () -> Void

    public init(
        recheck: @escaping @MainActor () -> Void = {},
        reloadAdapters: @escaping @MainActor () -> Void = {},
        saveSettings: @escaping @MainActor (AppSettings) -> Void = { _ in },
        setLoginItemEnabled: @escaping @MainActor (Bool) throws -> LoginItemStatus = { _ in .unavailable },
        loginItemStatus: @escaping @MainActor () -> LoginItemStatus = { .unavailable },
        openLoginItemSettings: @escaping @MainActor () -> Void = {},
        requestNotificationAuthorization: @escaping @MainActor () async -> NotificationAuthorization = { .denied },
        notificationAuthorization: @escaping @MainActor () async -> NotificationAuthorization = { .denied },
        notificationsAvailable: @escaping @MainActor () -> Bool = { false },
        openNotificationSettings: @escaping @MainActor () -> Void = {},
        diagnosticText: @escaping @MainActor (AppModel) -> String = { AppModel.defaultDiagnosticText($0) },
        copyToPasteboard: @escaping @MainActor (String) -> Void = { _ in },
        openURL: @escaping @MainActor (URL) -> Void = { _ in },
        quit: @escaping @MainActor () -> Void = {}
    ) {
        self.recheck = recheck
        self.reloadAdapters = reloadAdapters
        self.saveSettings = saveSettings
        self.setLoginItemEnabled = setLoginItemEnabled
        self.loginItemStatus = loginItemStatus
        self.openLoginItemSettings = openLoginItemSettings
        self.requestNotificationAuthorization = requestNotificationAuthorization
        self.notificationAuthorization = notificationAuthorization
        self.notificationsAvailable = notificationsAvailable
        self.openNotificationSettings = openNotificationSettings
        self.diagnosticText = diagnosticText
        self.copyToPasteboard = copyToPasteboard
        self.openURL = openURL
        self.quit = quit
    }

    /// 实际运行时的动作。`recheck`、`reloadAdapters` 与 `settingsDidChange` 由调度器提供。
    ///
    /// - saveSettings：写入 `settingsStore`，再调用 `settingsDidChange`。
    /// - 登录项：委托给 `loginItem`（SMAppService.mainApp）。
    /// - 通知：委托给 `notifier`；是否可用取 `UserNotificationCenterNotifier.isAvailable`。
    /// - 剪贴板、外部链接、退出：NSPasteboard、NSWorkspace、NSApp.terminate。
    @MainActor
    public static func live(
        settingsStore: SettingsStore,
        notifier: UserNotifying,
        loginItem: LoginItemControlling,
        recheck: @escaping @MainActor () -> Void,
        reloadAdapters: @escaping @MainActor () -> Void = {},
        settingsDidChange: @escaping @MainActor (AppSettings) -> Void = { _ in }
    ) -> AppActions {
        AppActions(
            recheck: recheck,
            reloadAdapters: reloadAdapters,
            saveSettings: { settings in
                settingsStore.save(settings)
                settingsDidChange(settings)
            },
            setLoginItemEnabled: { enabled in
                try loginItem.setEnabled(enabled)
                return loginItem.status
            },
            loginItemStatus: { loginItem.status },
            openLoginItemSettings: { loginItem.openSystemSettings() },
            requestNotificationAuthorization: {
                _ = await notifier.requestAuthorization()
                return await notifier.authorizationStatus()
            },
            notificationAuthorization: { await notifier.authorizationStatus() },
            notificationsAvailable: {
                (notifier as? UserNotificationCenterNotifier)?.isAvailable ?? true
            },
            openNotificationSettings: { SystemSettingsLinks.openNotificationSettings() },
            copyToPasteboard: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            },
            openURL: { url in NSWorkspace.shared.open(url) },
            quit: { NSApp.terminate(nil) }
        )
    }
}
