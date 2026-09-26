import AppKit
import Foundation
import TunCanaryCore

/// 进程所在的包环境。UNUserNotificationCenter 与 SMAppService.mainApp 只能在 `.app` 包内使用，
/// 在命令行（`swift run`、自带测试运行器）中调用会崩溃或报错，所以先用它判断。
public struct AppBundleEnvironment: Sendable, Equatable {
    public var bundleIdentifier: String?
    public var bundlePath: String

    public init(bundleIdentifier: String?, bundlePath: String) {
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
    }

    /// 当前进程。
    public static var current: AppBundleEnvironment {
        AppBundleEnvironment(bundleIdentifier: Bundle.main.bundleIdentifier, bundlePath: Bundle.main.bundlePath)
    }

    /// 运行在 `.app` 包内：bundle id 非空，且包路径以 `.app` 结尾。
    public var isAppBundle: Bool {
        guard let id = bundleIdentifier, !id.isEmpty else { return false }
        var path = bundlePath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.lowercased().hasSuffix(".app")
    }
}

/// 打开系统设置中的相关页面。
public enum SystemSettingsLinks {
    /// 通知设置中本应用的页面（macOS 13 起的系统设置）；打不开时退回通知总页。
    public static func notificationSettingsURLs(bundleID: String = AppIdentity.bundleID) -> [URL] {
        [
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)"),
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
            URL(string: "x-apple.systempreferences:com.apple.preference.notifications"),
        ].compactMap { $0 }
    }

    /// 打开通知设置。只打开页面，不修改任何设置。
    @MainActor
    public static func openNotificationSettings(bundleID: String = AppIdentity.bundleID) {
        for url in notificationSettingsURLs(bundleID: bundleID) where NSWorkspace.shared.open(url) {
            return
        }
    }
}
