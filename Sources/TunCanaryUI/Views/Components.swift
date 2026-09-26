import AppKit
import SwiftUI
import TunCanaryCore

/// 弹窗尺寸。
public enum PopoverMetrics {
    /// 弹窗宽度（点）。
    public static let width: CGFloat = 380
    /// 内容左右边距。
    static let padding: CGFloat = 14
    /// 可滚动区域的默认最大高度；nil 表示不限（离屏渲染时展开全部内容）。
    public static let defaultMaxScrollHeight: CGFloat = 440
}

// MARK: - 状态徽标

/// 状态徽标：彩色圆底 + 形状符号（✓ ! ✕ ?），与菜单栏徽标同一套绘制代码。
struct SeverityBadge: View {
    let severity: Severity
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Image(nsImage: Self.image(severity: severity, size: size, dark: dark))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel(Text(severity.displayName))
    }

    /// 按固定外观渲染（SwiftUI 中取不到绘制时外观，这里显式传入）。
    static func image(severity: Severity, size: CGFloat, dark: Bool) -> NSImage {
        let scale: CGFloat = 3
        guard let cg = LogoRenderer.rasterize(size: CGSize(width: size, height: size), scale: scale, draw: { ctx in
            LogoRenderer.drawBadge(in: ctx, center: CGPoint(x: size / 2, y: size / 2), radius: size / 2,
                                   severity: severity, dark: dark)
        }) else { return NSImage() }
        return NSImage(cgImage: cg, size: CGSize(width: size, height: size))
    }
}

// MARK: - 可限高滚动

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 内容不超过 `maxHeight` 时按内容高度显示，超过时滚动；`maxHeight` 为 nil 时不滚动（离屏渲染用）。
struct BoundedScroll<Content: View>: View {
    let maxHeight: CGFloat?
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        if let maxHeight {
            ScrollView(.vertical) {
                content()
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    })
            }
            .frame(height: min(max(contentHeight, 1), maxHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        } else {
            content()
        }
    }
}

// MARK: - 标题与卡片

/// 分节标题。
struct SectionTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(nil)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// 卡片背景：底色 + 描边，黄红卡片带淡淡的状态色。
struct CardBackground: ViewModifier {
    let tone: StatusTone

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tone.cardFill))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(tone.cardStroke, lineWidth: 0.75))
    }
}

extension View {
    func cardBackground(_ tone: StatusTone = .neutral) -> some View {
        modifier(CardBackground(tone: tone))
    }
}

/// 二级页面的顶栏：返回按钮 + 居中标题。
struct PanelNavBar: View {
    let title: String
    let back: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button(action: back) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("返回")
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }
}

// MARK: - 按钮样式（自绘，保证在弹窗与离屏渲染中外观一致）

/// 胶囊按钮：`prominent` 为品牌色实底，否则为浅灰底。
struct PillButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        PillButton(configuration: configuration, prominent: prominent, compact: compact)
    }

    private struct PillButton: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 11.5 : 12.5, weight: prominent ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, compact ? 9 : 12)
                .padding(.vertical, compact ? 4 : 6)
                .foregroundColor(prominent ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? Color(nsColor: StatusPalette.accent) : Color.primary.opacity(0.075)))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(prominent ? 0 : 0.08), lineWidth: 0.75))
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
                .contentShape(Rectangle())
        }
    }
}

/// 无底色的文字按钮（返回、设置、退出）。
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration)
    }

    private struct QuietButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5))
                .foregroundColor(.primary.opacity(0.85))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : 0))))
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// 整行可点的入口（手动恢复步骤、检测页）。
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButton(configuration: configuration)
    }

    private struct RowButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5))
                .foregroundColor(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : (hovering ? 0.075 : 0.045))))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// 细进度条（自绘，不依赖 NSProgressIndicator 动画）。
struct ThinProgressBar: View {
    /// nil 表示总数未知，显示一段静态的短条。
    let fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color(nsColor: StatusPalette.accent))
                    .frame(width: max(4, proxy.size.width * CGFloat(fraction ?? 0.3)))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// 带图标的提示框（设置页中的“系统通知已关闭”等）。
struct CalloutBox<Actions: View>: View {
    let tone: StatusTone
    let icon: String
    let title: String
    var detail: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tone.textColor)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tone.textColor)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .cardBackground(tone)
    }
}

extension CalloutBox where Actions == EmptyView {
    init(tone: StatusTone, icon: String, title: String, detail: String? = nil) {
        self.init(tone: tone, icon: icon, title: title, detail: detail) { EmptyView() }
    }
}
