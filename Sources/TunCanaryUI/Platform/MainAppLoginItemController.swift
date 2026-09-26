import Foundation
import TunCanaryCore
import ServiceManagement

/// 登录项操作错误。`message` 为界面直接展示的中文。
public enum LoginItemControlError: Error, Equatable, LocalizedError {
    /// 不在 `.app` 包内运行。
    case unavailable
    /// 系统拒绝（例如 ad-hoc 签名重装后失效）。
    case failed(String)

    public var message: String {
        switch self {
        case .unavailable:
            return "登录时启动仅在安装后的应用包中可用"
        case .failed(let reason):
            return "无法更改登录时启动：\(reason)"
        }
    }

    public var errorDescription: String? { message }
}

/// 注销登录项的结果。`message` 为命令行直接打印的中文说明。
public enum LoginItemUnregisterResult: String, Sendable, Equatable {
    case unregistered
    /// 系统登记为未注册，无需注销。
    case notRegistered
    /// 系统找不到本应用的登录项（.notFound），视为未注册。
    case notFound

    public var message: String {
        switch self {
        case .unregistered: return "已注销登录时启动。"
        case .notRegistered: return "登录时启动未注册，无需注销。"
        case .notFound: return "系统中未找到本应用的登录项，视为未注册，无需注销。"
        }
    }
}

/// `SMAppService` 中登录项控制用到的部分；测试可注入桩，不触碰系统登记。
public protocol MainAppServiceControlling: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: MainAppServiceControlling {}

/// 基于 `SMAppService.mainApp` 的登录时启动控制（macOS 13+）。
///
/// 不在 `.app` 包内运行时：状态为 `.unavailable`，`setEnabled` 抛出 `.unavailable`，
/// `openSystemSettings` 为空操作，全程不触碰 SMAppService。
public final class MainAppLoginItemController: LoginItemControlling {
    public let environment: AppBundleEnvironment
    private let openLoginItemsSettings: () -> Void
    private let makeService: () -> MainAppServiceControlling

    /// - Parameters:
    ///   - openSettings: 打开“系统设置 → 登录项”的实现，默认调用
    ///     `SMAppService.openSystemSettingsLoginItems()`；测试可注入桩。
    ///   - service: 登录项服务，默认 `SMAppService.mainApp`；测试可注入桩。
    public init(environment: AppBundleEnvironment = .current, openSettings: (() -> Void)? = nil,
                service: MainAppServiceControlling? = nil) {
        self.environment = environment
        self.openLoginItemsSettings = openSettings ?? { SMAppService.openSystemSettingsLoginItems() }
        self.makeService = service.map { injected in { injected } } ?? { SMAppService.mainApp }
    }

    public var status: LoginItemStatus {
        guard environment.isAppBundle else { return .unavailable }
        return Self.map(makeService().status)
    }

    public func setEnabled(_ enabled: Bool) throws {
        guard environment.isAppBundle else { throw LoginItemControlError.unavailable }
        let service = makeService()
        do {
            if enabled {
                guard service.status != .enabled else { return }
                // .notFound 表示系统查找服务时出错，仍允许用户尝试重新注册。
                try service.register()
            } else {
                _ = try unregister(service)
            }
        } catch let error as LoginItemControlError {
            throw error
        } catch {
            throw LoginItemControlError.failed(error.localizedDescription)
        }
    }

    /// 注销登录项。只有已启用或待批准时才调用系统注销；未注册或系统找不到服务（.notFound）时无需注销，
    /// 直接返回说明。卸载脚本经由 `--unregister-login-item` 调用。
    public func unregisterIfNeeded() throws -> LoginItemUnregisterResult {
        guard environment.isAppBundle else { throw LoginItemControlError.unavailable }
        do {
            return try unregister(makeService())
        } catch {
            throw LoginItemControlError.failed(error.localizedDescription)
        }
    }

    private func unregister(_ service: MainAppServiceControlling) throws -> LoginItemUnregisterResult {
        switch service.status {
        case .enabled, .requiresApproval:
            try service.unregister()
            return .unregistered
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    public func openSystemSettings() {
        guard environment.isAppBundle else { return }
        openLoginItemsSettings()
    }

    /// 系统状态 → Core 的登录项状态。
    public static func map(_ status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
}
