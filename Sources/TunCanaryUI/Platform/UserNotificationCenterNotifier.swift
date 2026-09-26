import Foundation
import TunCanaryCore
import UserNotifications

/// 基于 UNUserNotificationCenter 的通知发送。
///
/// 只有进程运行在 `.app` 包内时才会触碰 UNUserNotificationCenter；否则（命令行、测试）
/// 全部为空操作：`isAvailable` 为 false，申请权限返回 false，授权状态视为 `.denied`（不可发送）。
/// Core 的 `NotificationAuthorization` 没有“不可用”一项，界面用 `isAvailable` 区分。
public final class UserNotificationCenterNotifier: NSObject, UserNotifying, UNUserNotificationCenterDelegate {
    public let environment: AppBundleEnvironment
    /// 用户点击通知时回调（例如打开弹窗），在主线程调用。
    public var onActivate: (@MainActor () -> Void)?

    public init(environment: AppBundleEnvironment = .current) {
        self.environment = environment
        super.init()
        if isAvailable {
            // 应用在前台（弹窗打开）时也要显示横幅，需要设置代理。
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// 是否可以使用系统通知（运行在 `.app` 包内）。
    public var isAvailable: Bool {
        environment.isAppBundle
    }

    public func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    public func authorizationStatus() async -> NotificationAuthorization {
        guard isAvailable else { return .denied }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    public func deliver(_ notification: PendingNotification) async {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.threadIdentifier = "tuncanary.status"
        if notification.severity == .critical {
            content.sound = .default
        }
        let identifier = "tuncanary.\(notification.key.rawValue).\(Int(Date().timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// 系统授权状态 → Core 的授权状态。临时授权（provisional）视为已授权。
    public static func map(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional: return .authorized
        @unknown default: return .authorized
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let handler = onActivate
        Task { @MainActor in handler?() }
        completionHandler()
    }
}
