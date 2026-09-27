import Foundation

/// 应用身份。bundle id 始终保持不变，避免重装后通知权限失效。
public enum AppIdentity {
    public static let bundleID = "io.github.eastcn.tuncanary"
    /// 可执行文件与 `.app` 名称。
    public static let name = "TunCanary"
    /// 界面显示名称。
    public static let displayName = "TunCanary"
    /// 版本号。`scripts/build-app.sh` 从这里读取并写入 Info.plist，只在此处修改。
    public static let version = "0.1.0"
}

/// 已知路径。全部以 home 目录为参数计算，不写死用户名。
public struct KnownPaths: Sendable, Equatable {
    /// 当前用户主目录，例如 `/Users/<name>`。
    public let homeDirectory: String

    public init(homeDirectory: String) {
        var home = homeDirectory
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        self.homeDirectory = home
    }

    /// 当前用户（读取进程环境，不访问文件）。
    public static func currentUser() -> KnownPaths {
        KnownPaths(homeDirectory: NSHomeDirectory())
    }

    private func underHome(_ relative: String) -> String {
        homeDirectory + "/" + relative
    }

    // MARK: Clash Verge

    /// Clash Verge Rev 配置目录。
    public var clashVergeConfigDirectory: String {
        underHome("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev")
    }

    /// `verge.yaml`（读取 `enable_tun_mode`）。
    public var vergeConfigFile: String {
        clashVergeConfigDirectory + "/verge.yaml"
    }

    /// `clash-verge.yaml`（读取 `tun.*`、`dns.*`）。
    public var clashVergeConfigFile: String {
        clashVergeConfigDirectory + "/clash-verge.yaml"
    }

    /// Mihomo 进程名。
    public static let mihomoProcessName = "verge-mihomo"

    // MARK: TunCanary

    /// 声明式 VPN 适配器配置目录，每个 `.json` 文件一个适配器。
    public var vpnAdaptersDirectory: String {
        underHome("Library/Application Support/\(AppIdentity.name)/adapters")
    }

    /// 故障事件日志（JSON Lines）。
    public var faultEventLogFile: String {
        underHome("Library/Application Support/\(AppIdentity.name)/events.jsonl")
    }

    /// 把 `~/` 开头的路径展开到 `home` 下；其他路径原样返回。
    public static func expandTilde(_ path: String, home: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        var base = home
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        return base + path.dropFirst()
    }
}

/// 计划中约定的时间、次数和阈值，供各模块共用。
public enum PulseConstants {
    /// 本机检查周期（秒）。
    public static let localCheckInterval: TimeInterval = 20
    /// 后台轻测周期（秒）。
    public static let lightProbeInterval: TimeInterval = 120
    /// 网络变化或唤醒后的宽限期（秒）。
    public static let gracePeriod: TimeInterval = 10
    /// 网络事件去抖（秒）。
    public static let eventDebounce: TimeInterval = 2
    /// Mihomo DNS 查询超时（秒）。
    public static let mihomoDNSTimeout: TimeInterval = 2
    /// 只读命令（scutil、netstat）超时（秒）。
    public static let commandTimeout: TimeInterval = 3
    /// 完整检测每站请求次数。
    public static let fullProbeAttempts = 3
    /// 后台轻测每站请求次数。
    public static let lightProbeAttempts = 1
    /// `--check` 轻测中每个关键站点的最多请求次数。
    public static let cliProbeMaxAttempts = 2
    /// 单次请求超时（秒）。
    public static let probeTimeout: TimeInterval = 4
    /// 完整检测最多并发站点数。
    public static let fullProbeConcurrency = 3
    /// `--check` 本机结果为黄或红时的复查间隔（秒）。
    public static let cliRecheckDelay: TimeInterval = 10
    /// `--check` 整体超时（秒）。
    public static let cliOverallTimeout: TimeInterval = 30
    /// 收到睡眠事件后等待唤醒的兜底时长（秒，单调时钟）。真正睡眠时单调时钟不走，到点说明并未睡着。
    public static let sleepFallbackDelay: TimeInterval = 60
    /// 连续失败门槛（轮）。
    public static let consecutiveFailureThreshold = 2
    /// 每站保留的历史结果数。
    public static let siteHistoryLimit = 5
    /// 状态文件与网段都无法识别 VPN 隧道时，按路由数量回退识别所需的默认最少条数。
    public static let vpnFallbackMinRoutes = 10
    /// 系统解析 canary 域名。
    public static let canaryHost = "www.google.com"
    /// Mihomo DNS 查询地址。
    public static let mihomoDNSHost = "127.0.0.1"
}
