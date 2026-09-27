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
    /// 分节之间的间距。
    static let sectionSpacing: CGFloat = 14
    /// 卡片内一行的水平、垂直内边距。
    static let rowHorizontal: CGFloat = 10
    static let rowVertical: CGFloat = 7
}

/// 弹窗字号：首页与设置页共用这四档。
enum Typography {
    /// 分节标题（卡片外、上方）。
    static let sectionTitle = Font.system(size: 11, weight: .semibold)
    /// 行标题、输入框、开关文字。
    static let rowTitle = Font.system(size: 12.5)
    /// 正文、结论。
    static let body = Font.system(size: 12)
    /// 说明、次要信息。
    static let caption = Font.system(size: 11)
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
                .font(Typography.sectionTitle)
                .foregroundColor(.secondary)
                .textCase(nil)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(Typography.caption)
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

/// 一张分组卡片：行与行之间用缩进的分隔线隔开。子视图用 `GroupRows` 逐行给出。
struct GroupCard<Content: View>: View {
    var tone: StatusTone = .neutral
    @ViewBuilder var content: () -> Content

    var body: some View {
        _VariadicView.Tree(GroupRowsLayout()) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .cardBackground(tone)
    }
}

/// `GroupCard` 的布局：在相邻子视图之间插入分隔线。
private struct GroupRowsLayout: _VariadicView_UnaryViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                if child.id != children.first?.id {
                    Divider().padding(.leading, PopoverMetrics.rowHorizontal)
                }
                child
            }
        }
    }
}

/// 分节：标题在上，分组卡片在下，卡片下方可附说明。
struct FormSection<Content: View>: View {
    let title: String
    var trailing: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: title, trailing: trailing)
                .padding(.horizontal, 2)
            GroupCard(content: content)
            if let footer {
                Text(footer)
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// 卡片内的一行：左标签、右控件；下方可附一行说明或错误。
struct FormRow<Control: View>: View {
    let label: String
    var badge: String?
    var caption: String?
    var error: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Text(label)
                        .font(Typography.rowTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    if let badge { TagLabel(text: badge) }
                }
                .layoutPriority(1)
                Spacer(minLength: 6)
                control()
            }
            FieldNote(caption: caption, error: error)
        }
        .rowPadding()
    }
}

/// 卡片内的一行：标签在上、输入框在下，用于 URL 等长值。
struct FormFieldRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var caption: String?
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(Typography.rowTitle)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Typography.rowTitle)
                .accessibilityLabel(Text(label))
                .errorOutline(error != nil)
            FieldNote(caption: caption, error: error)
        }
        .rowPadding()
    }
}

/// 右侧窄输入框，可带单位（设置页的间隔、端口）。
struct CompactField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var unit: String?
    var width: CGFloat = 90
    var hasError = false

    var body: some View {
        HStack(spacing: 5) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Typography.rowTitle)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .accessibilityLabel(Text(label))
                .errorOutline(hasError)
            if let unit {
                Text(unit)
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// 字段下方：有错误时显示错误，否则显示说明。
struct FieldNote: View {
    var caption: String?
    var error: String?

    var body: some View {
        if let error {
            ErrorText(text: error)
        } else if let caption {
            Text(caption)
                .font(Typography.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 红色错误文字。
struct ErrorText: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(Typography.caption)
            .foregroundColor(StatusTone.critical.textColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 细边框小标签（“关键”“立即生效”）。
struct TagLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 3.5)
            .padding(.vertical, 0.5)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 0.6))
            .fixedSize()
    }
}

/// 可折叠的一行：箭头、标题、右侧摘要；展开后在下方显示内容。
struct DisclosureRow<Content: View>: View {
    let title: String
    var trailing: String?
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Text(title)
                        .font(Typography.rowTitle)
                        .foregroundColor(.primary)
                    Spacer(minLength: 6)
                    if let trailing {
                        Text(trailing)
                            .font(Typography.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
            if isExpanded {
                content()
            }
        }
        .rowPadding()
    }
}

/// 分节下方默认收起的“说明”：放较长的补充说明，不占版面。
struct NotesDisclosure: View {
    let notes: [String]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "info.circle")
                    Text(isExpanded ? "收起说明" : "说明")
                }
                .font(Typography.caption)
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 2)
    }
}

extension View {
    /// 卡片内一行的标准内边距。
    func rowPadding() -> some View {
        padding(.horizontal, PopoverMetrics.rowHorizontal)
            .padding(.vertical, PopoverMetrics.rowVertical)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 输入有误时的红色描边。
    func errorOutline(_ show: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(StatusTone.critical.markColor, lineWidth: show ? 1.2 : 0)
                .allowsHitTesting(false))
    }
}

// MARK: - 分段控件

/// 自绘分段控件（保证在弹窗与离屏渲染中外观一致）。`marked` 中的选项右上角显示红点。
struct SegmentedTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    var marked: Set<Tab> = []
    @Environment(\.colorScheme) private var colorScheme

    private var selectedFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.white
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 4) {
                        Text(title(tab))
                        if marked.contains(tab) {
                            Circle()
                                .fill(StatusTone.critical.markColor)
                                .frame(width: 6, height: 6)
                                .accessibilityLabel(Text("有错误"))
                        }
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundColor(.primary.opacity(selected ? 1 : 0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? selectedFill : Color.clear)
                            .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 0.5, y: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.07)))
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
