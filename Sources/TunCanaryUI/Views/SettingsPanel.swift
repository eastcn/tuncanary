import SwiftUI
import TunCanaryCore

/// 设置页：顶部分栏切换“站点”“代理与 DNS”“通用”，底部统一保存。
struct SettingsPanel: View {
    @ObservedObject var model: AppModel
    let maxScrollHeight: CGFloat?

    var body: some View {
        let validation = model.settingsValidation
        let errorTabs = validation.tabsWithErrors
        VStack(spacing: 0) {
            PanelNavBar(title: "设置") { model.showMain() }
            SegmentedTabs(tabs: SettingsTab.allCases, selection: $model.settingsTab,
                          title: \.title, marked: errorTabs)
                .padding(.horizontal, PopoverMetrics.padding)
                .padding(.bottom, 10)
            Divider()
            BoundedScroll(maxHeight: maxScrollHeight) {
                VStack(alignment: .leading, spacing: PopoverMetrics.sectionSpacing) {
                    switch model.settingsTab {
                    case .sites: SettingsSitesTab(model: model, validation: validation)
                    case .proxyDNS: SettingsProxyDNSTab(model: model, validation: validation)
                    case .general: SettingsGeneralTab(model: model, validation: validation)
                    }
                }
                .padding(PopoverMetrics.padding)
            }
            Divider()
            HStack(spacing: 8) {
                if model.showsSavedFeedback {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(StatusTone.ok.textColor)
                } else if let first = validation.firstTabWithErrors {
                    Button {
                        model.showFirstSettingsError()
                    } label: {
                        Text("请先修正标红的项（\(SettingsTab.allCases.filter(errorTabs.contains).map(\.title).joined(separator: "、"))）")
                            .font(Typography.caption)
                            .foregroundColor(StatusTone.critical.textColor)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .help("转到“\(first.title)”")
                }
                Spacer(minLength: 4)
                Button("取消") { model.showMain() }
                    .buttonStyle(PillButtonStyle(compact: true))
                Button("保存") { model.saveSettings() }
                    .buttonStyle(PillButtonStyle(prominent: true, compact: true))
                    .disabled(!model.canSaveSettings)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, PopoverMetrics.padding)
            .padding(.vertical, 10)
        }
    }
}

/// 文本输入 + 说明（标签在上）；有错误时在输入框下方显示错误（替代说明）。用于站点编辑器等卡片内的嵌套表单。
struct SettingsTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let caption: String?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Typography.rowTitle)
                .accessibilityAddTraits(.isHeader)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Typography.rowTitle)
                .accessibilityLabel(Text(title))
                .errorOutline(error != nil)
            FieldNote(caption: caption, error: error)
        }
    }
}

/// 设置页里的开关（小号、右对齐）。
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}
