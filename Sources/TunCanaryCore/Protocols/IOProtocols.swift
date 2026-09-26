import Foundation

// I/O 协议。Core 只定义接口，便于在测试中注入桩实现。

/// 采集一轮本机状态（实现见 TunCanarySystem）。
///
/// 不抛错：每一项的失败都写进 `LocalSnapshot` 对应字段（`.failed(reason:)`、`.unreadable` 等）。
/// 实现须遵守计划：优先系统 API；只读命令每轮最多一次、超时 3 秒；不读取 Clash secret；
/// VPN 状态文件只取适配器配置指定的字段。
public protocol LocalSnapshotProviding {
    func collectSnapshot() async -> LocalSnapshot
}

/// 探测一个站点（实现见 TunCanaryProbe）。
///
/// 串行发起 `attempts` 次 GET（不跟随重定向、收到响应头即取消、每次新的 ephemeral 会话），
/// 单次超时 `timeout` 秒，用 `SiteAggregator.aggregate` 汇总后返回。不抛错。
public protocol SiteProbing {
    func probe(site: Site, attempts: Int, timeout: TimeInterval) async -> SiteResult
}

/// 监听网络变化、唤醒与睡眠（实现见 TunCanarySystem）。实现负责 2 秒去抖；回调可能在任意线程。
public protocol NetworkChangeObserving: AnyObject {
    func start(handler: @escaping @Sendable (NetworkChangeEvent) -> Void)
    func stop()
}

/// 通知授权状态。
public enum NotificationAuthorization: String, Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}

/// 发送用户通知（实现见 TunCanaryUI）。命令行模式不使用。
public protocol UserNotifying: AnyObject {
    /// 申请通知权限（首次启动时调用），返回是否获准。
    func requestAuthorization() async -> Bool
    func authorizationStatus() async -> NotificationAuthorization
    func deliver(_ notification: PendingNotification) async
}

/// 登录时启动的系统实际状态。
public enum LoginItemStatus: String, Sendable, Equatable {
    case enabled
    case disabled
    /// 需要在系统设置中批准。
    case requiresApproval
    /// 不可用（如 ad-hoc 签名重装后失效、应用不在稳定位置）。
    case unavailable

    public var displayName: String {
        switch self {
        case .enabled: return "已开启"
        case .disabled: return "已关闭"
        case .requiresApproval: return "需要在系统设置中批准"
        case .unavailable: return "不可用"
        }
    }
}

/// 控制登录时启动（实现见 TunCanaryUI，基于 SMAppService.mainApp）。
public protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    /// 打开“系统设置 → 登录项”。
    func openSystemSettings()
}
