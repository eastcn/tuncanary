import AppKit
import SwiftUI
import TunCanaryCore

/// 界面色调。状态卡、站点结果和历史标记都映射到这里，再由 `StatusPalette` 给出具体颜色。
public enum StatusTone: String, Sendable, CaseIterable, Equatable {
    /// 绿：正常、可达。
    case ok
    /// 黄：需关注。
    case warning
    /// 红：故障、计为失败的探测结果。
    case critical
    /// 灰：未确认、尚未检测、未探测。
    case neutral
    /// 蓝：有响应但访问受限（4xx），不计为失败。
    case info

    public init(_ severity: Severity) {
        switch severity {
        case .ok: self = .ok
        case .warning: self = .warning
        case .critical: self = .critical
        case .unknown: self = .neutral
        }
    }

    /// 探测类别的色调：可达为绿，4xx 为蓝，本地网络权限被拒为灰，其余（计为失败）为红。
    public init(_ category: ProbeCategory) {
        switch category {
        case .reachable: self = .ok
        case .restricted: self = .info
        case .localNetworkDenied: self = .neutral
        case .serverError, .tlsError, .timeout, .dnsFailure, .connectionFailure: self = .critical
        }
    }
}

/// 配色。徽标用鲜明的系统色；文字用对比度更高的深浅两套颜色。
public enum StatusPalette {
    /// 由深浅两种颜色组成的动态颜色。
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.isDarkAppearance ? dark : light
        }
    }

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }

    /// 徽标底色（圆形），深浅外观各一套。
    public static func badgeFill(_ severity: Severity, dark: Bool) -> NSColor {
        switch severity {
        case .ok: return dark ? rgb(0x30D158) : rgb(0x28B84C)
        case .warning: return dark ? rgb(0xFFD60A) : rgb(0xF5B800)
        case .critical: return dark ? rgb(0xFF453A) : rgb(0xE5362C)
        case .unknown: return dark ? rgb(0x8E8E93) : rgb(0x8A8A8F)
        }
    }

    /// 徽标内符号颜色：黄底用深色，其余用白色，保证对比度。
    public static func badgeGlyph(_ severity: Severity, dark: Bool) -> NSColor {
        switch severity {
        case .warning: return rgb(0x3D2E00)
        case .ok, .critical, .unknown: return .white
        }
    }

    /// 文字色（对比度优先，黄色在浅色背景下改用琥珀色）。
    public static func text(_ tone: StatusTone) -> NSColor {
        switch tone {
        case .ok: return dynamic(light: rgb(0x1A7F37), dark: rgb(0x3FD466))
        case .warning: return dynamic(light: rgb(0x9A6700), dark: rgb(0xFFD23F))
        case .critical: return dynamic(light: rgb(0xCF222E), dark: rgb(0xFF6B61))
        case .neutral: return dynamic(light: rgb(0x6E6E73), dark: rgb(0x98989D))
        case .info: return dynamic(light: rgb(0x0969DA), dark: rgb(0x64B5FF))
        }
    }

    /// 标记与图形用的实色（历史圆点等）。
    public static func mark(_ tone: StatusTone) -> NSColor {
        switch tone {
        case .ok: return dynamic(light: rgb(0x28B84C), dark: rgb(0x30D158))
        case .warning: return dynamic(light: rgb(0xF5B800), dark: rgb(0xFFD60A))
        case .critical: return dynamic(light: rgb(0xE5362C), dark: rgb(0xFF453A))
        case .neutral: return dynamic(light: rgb(0xAEAEB2), dark: rgb(0x636366))
        case .info: return dynamic(light: rgb(0x2F81F7), dark: rgb(0x58A6FF))
        }
    }

    /// 卡片底色：正常与灰色用中性浅底，黄红用淡淡的状态色。
    public static func cardFill(_ tone: StatusTone) -> NSColor {
        switch tone {
        case .ok, .neutral, .info:
            return dynamic(light: NSColor.black.withAlphaComponent(0.035), dark: NSColor.white.withAlphaComponent(0.055))
        case .warning:
            return dynamic(light: rgb(0xF5B800, alpha: 0.12), dark: rgb(0xFFD60A, alpha: 0.10))
        case .critical:
            return dynamic(light: rgb(0xE5362C, alpha: 0.09), dark: rgb(0xFF453A, alpha: 0.13))
        }
    }

    /// 卡片描边。
    public static func cardStroke(_ tone: StatusTone) -> NSColor {
        switch tone {
        case .ok, .neutral, .info:
            return dynamic(light: NSColor.black.withAlphaComponent(0.07), dark: NSColor.white.withAlphaComponent(0.09))
        case .warning:
            return dynamic(light: rgb(0xD29A00, alpha: 0.45), dark: rgb(0xFFD60A, alpha: 0.35))
        case .critical:
            return dynamic(light: rgb(0xE5362C, alpha: 0.40), dark: rgb(0xFF453A, alpha: 0.45))
        }
    }

    /// 主按钮底色（品牌色，深青）。
    public static let accent = dynamic(light: rgb(0x0B7A75), dark: rgb(0x1FB5A8))
}

extension StatusTone {
    /// 文字色。
    public var textColor: Color { Color(nsColor: StatusPalette.text(self)) }
    /// 标记色。
    public var markColor: Color { Color(nsColor: StatusPalette.mark(self)) }
    /// 卡片底色。
    public var cardFill: Color { Color(nsColor: StatusPalette.cardFill(self)) }
    /// 卡片描边。
    public var cardStroke: Color { Color(nsColor: StatusPalette.cardStroke(self)) }
}

extension NSAppearance {
    /// 是否为深色外观。
    public var isDarkAppearance: Bool {
        bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark,
                         .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                         .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark])
            .map { [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark].contains($0) }
            ?? false
    }
}
