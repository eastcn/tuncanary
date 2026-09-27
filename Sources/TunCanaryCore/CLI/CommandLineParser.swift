import Foundation

/// `--check` 的退出码。
public enum CLIExitCode: Int32, Sendable, Codable {
    case ok = 0
    case warning = 1
    case critical = 2
    /// 未确认，含整体超时。
    case unconfirmed = 3
    /// 参数错误。
    case usage = 64

    public init(severity: Severity) {
        switch severity {
        case .ok: self = .ok
        case .warning: self = .warning
        case .critical: self = .critical
        case .unknown: self = .unconfirmed
        }
    }
}

/// `--check` 选项。
public struct CheckOptions: Sendable, Equatable {
    /// `--full`：完整检测（全部站点，每站 3 次）。
    public var full: Bool
    /// `--json`：输出 JSON。
    public var json: Bool

    public init(full: Bool = false, json: Bool = false) {
        self.full = full
        self.json = json
    }
}

/// 命令行解析结果。
public enum CommandLineMode: Sendable, Equatable {
    /// 启动菜单栏界面。
    case app
    case check(CheckOptions)
    case help
    /// `--version`：打印版本号。
    case version
    /// 参数错误，退出码 64。
    case usageError(String)
}

/// 解析命令行参数（不含 argv[0]）。
public enum CommandLineParser {
    public static let usage = """
    用法：
      TunCanary                              启动菜单栏应用
      TunCanary --check [--full] [--json]    单次检查
        --full   完整检测全部站点（默认只做一轮轻测）
        --json   输出 JSON
      TunCanary --version                    打印版本号
    退出码：0 正常，1 需关注，2 故障，3 未确认（含超时），64 参数错误
    """

    public static func parse(_ arguments: [String]) -> CommandLineMode {
        var check = false
        var full = false
        var json = false
        var help = false
        var version = false
        var unknown: [String] = []
        var system: [String] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--check": check = true
            case "--full": full = true
            case "--json": json = true
            case "--help", "-h": help = true
            case "--version": version = true
            default:
                if argument.hasPrefix("-psn_") {
                    system.append(argument)
                } else if argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") {
                    // 系统参数形如 -NSxxx <值>、-Applexxx <值>，连同后面的值一起放行。
                    system.append(argument)
                    if index + 1 < arguments.count {
                        index += 1
                        system.append(arguments[index])
                    }
                } else {
                    unknown.append(argument)
                }
            }
            index += 1
        }

        if help { return .help }
        if version {
            // 只接受单独使用，避免脚本误以为 `--check --version` 做了检查。
            let others = arguments.filter { $0 != "--version" }
            guard others.isEmpty else {
                return .usageError("--version 不能与其他参数一起使用")
            }
            return .version
        }
        if check {
            let rejected = system + unknown
            guard rejected.isEmpty else {
                return .usageError("未知参数：\(rejected.joined(separator: " "))")
            }
            return .check(CheckOptions(full: full, json: json))
        }
        if full || json {
            return .usageError("--full 与 --json 只能与 --check 一起使用")
        }
        // 启动界面时只放行系统可能附带的参数（-psn_*、-NS*、-Apple*）；拼错的选项不能静默启动界面。
        let options = unknown.filter { $0.hasPrefix("-") }
        guard options.isEmpty else {
            return .usageError("未知参数：\(options.joined(separator: " "))")
        }
        return .app
    }
}
