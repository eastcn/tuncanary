import Foundation

/// 检查结果的严重程度。排序为 故障（红）> 需关注（黄）> 未确认（灰）> 正常（绿）。
public enum Severity: String, Sendable, Codable, CaseIterable, Comparable {
    case ok
    case unknown
    case warning
    case critical

    /// 排序权重，越大越严重。
    public var rank: Int {
        switch self {
        case .ok: return 0
        case .unknown: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rank < rhs.rank
    }

    /// 状态标记形状，避免只靠颜色传达状态。
    public var symbol: String {
        switch self {
        case .ok: return "✓"
        case .unknown: return "?"
        case .warning: return "!"
        case .critical: return "✕"
        }
    }

    /// 中文状态名。
    public var displayName: String {
        switch self {
        case .ok: return "正常"
        case .unknown: return "未确认"
        case .warning: return "需关注"
        case .critical: return "故障"
        }
    }

    /// 颜色名，供界面映射到具体颜色。
    public var colorName: String {
        switch self {
        case .ok: return "green"
        case .unknown: return "gray"
        case .warning: return "yellow"
        case .critical: return "red"
        }
    }

    /// 黄或红才会产生故障键和通知；灰色不通知。
    public var isAlerting: Bool {
        self == .warning || self == .critical
    }

    /// 取最严重的一项；空序列视为正常。
    public static func worst<S: Sequence>(_ items: S) -> Severity where S.Element == Severity {
        items.max() ?? .ok
    }
}
