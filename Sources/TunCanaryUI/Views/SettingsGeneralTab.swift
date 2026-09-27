import SwiftUI
import TunCanaryCore

/// 设置 · 通用：检测频率、通知、登录时启动、VPN 适配器。
struct SettingsGeneralTab: View {
    @ObservedObject var model: AppModel
    let validation: SettingsDraft.Validation

    var body: some View {
        FormSection(title: "检测频率",
                    footer: "后台站点检测未结束时会合并触发，避免重叠请求。") {
            FormRow(label: "本机检查间隔",
                    caption: "默认 20 秒；可设置 5–3600 秒。",
                    error: validation.localCheckIntervalError) {
                CompactField(label: "本机检查间隔（秒）", placeholder: "20",
                             text: $model.settingsDraft.localCheckInterval, unit: "秒", width: 70,
                             hasError: validation.localCheckIntervalError != nil)
            }
            FormRow(label: "后台站点检测间隔",
                    caption: "默认 120 秒；可设置 15–86400 秒。",
                    error: validation.lightProbeIntervalError) {
                CompactField(label: "后台站点检测间隔（秒）", placeholder: "120",
                             text: $model.settingsDraft.lightProbeInterval, unit: "秒", width: 70,
                             hasError: validation.lightProbeIntervalError != nil)
            }
        }
        NotificationSettingsSection(model: model)
        LoginItemSection(model: model)
        VPNAdaptersSection(model: model)
    }
}

/// 通知开关与系统授权状态。
struct NotificationSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        FormSection(title: "通知",
                    footer: "同一故障只通知一次，同一轮的多条通知合并为一条；恢复和“未确认”不通知。通知内容不包含 VPN 站点 URL。") {
            FormRow(label: "出现需关注或故障时发送系统通知") {
                SettingsSwitch(label: "出现需关注或故障时发送系统通知",
                               isOn: $model.settingsDraft.notificationsEnabled)
            }
            status
        }
    }

    @ViewBuilder private var status: some View {
        if !model.notificationsAvailable {
            CalloutBox(tone: .neutral, icon: "bell.slash", title: "系统通知不可用",
                       detail: "当前未在应用包内运行（例如 swift run），不会发送系统通知。")
                .padding(8)
        } else {
            switch model.notificationAuthorization {
            case .denied:
                CalloutBox(tone: .warning, icon: "bell.slash.fill", title: "系统通知已关闭",
                           detail: "菜单栏和弹窗仍正常工作；需要通知时请在系统设置中允许 TunCanary。") {
                    Button("打开系统设置") { model.openNotificationSettings() }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .padding(.top, 2)
                }
                .padding(8)
            case .notDetermined:
                CalloutBox(tone: .neutral, icon: "bell", title: "尚未授权系统通知") {
                    Button("允许通知") { Task { await model.requestNotificationPermission() } }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .padding(.top, 2)
                }
                .padding(8)
            case .authorized:
                Label("系统通知已允许", systemImage: "checkmark.circle.fill")
                    .font(Typography.caption)
                    .foregroundColor(StatusTone.ok.textColor)
                    .rowPadding()
            }
        }
    }
}

/// 登录时启动：显示系统实际状态，操作立即生效（不随“保存”）。
struct LoginItemSection: View {
    @ObservedObject var model: AppModel

    /// 系统状态 .unavailable 也可能出现在已安装应用中，此时仍可尝试重新注册。
    private var isAppBundle: Bool { AppBundleEnvironment.current.isAppBundle }

    private var isOn: Binding<Bool> {
        Binding(
            get: { model.loginItemStatus == .enabled || model.loginItemStatus == .requiresApproval },
            set: { model.setLoginItemEnabled($0) })
    }

    var body: some View {
        FormSection(title: "登录时启动") {
            FormRow(label: "登录时自动启动 TunCanary", badge: "立即生效",
                    caption: "系统状态：\(model.loginItemStatus.displayName)。",
                    error: model.loginItemError) {
                SettingsSwitch(label: "登录时自动启动 TunCanary", isOn: isOn)
                    .disabled(!isAppBundle)
            }
            switch model.loginItemStatus {
            case .requiresApproval:
                CalloutBox(tone: .warning, icon: "exclamationmark.triangle.fill", title: "需要在系统设置中批准",
                           detail: "请在“系统设置 → 通用 → 登录项”中允许 TunCanary，登录时启动才会生效。") {
                    Button("打开登录项设置") { model.openLoginItemSettings() }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .padding(.top, 2)
                }
                .padding(8)
            case .unavailable:
                if isAppBundle {
                    CalloutBox(tone: .warning, icon: "exclamationmark.triangle.fill", title: "登录项状态不可用",
                               detail: "可尝试打开上方开关重新注册。若仍无法启用，请查看错误信息并检查系统设置中的登录项。") {
                        Button("打开登录项设置") { model.openLoginItemSettings() }
                            .buttonStyle(PillButtonStyle(compact: true))
                            .padding(.top, 2)
                    }
                    .padding(8)
                } else {
                    CalloutBox(tone: .neutral, icon: "info.circle", title: "登录时启动不可用",
                               detail: "仅在安装后的应用包中可用；当前运行环境不会调用系统登录项接口。")
                        .padding(8)
                }
            case .enabled, .disabled:
                EmptyView()
            }
        }
    }
}

/// VPN 适配器：显示已加载的适配器和无效文件，可以立即重新读取目录（不随“保存”）。
struct VPNAdaptersSection: View {
    @ObservedObject var model: AppModel

    private var loadedText: String {
        let adapters = model.adapterSet.adapters
        guard !adapters.isEmpty else { return "未加载适配器" }
        return "已加载 \(adapters.count) 个：\(adapters.map(\.name).joined(separator: "、"))"
    }

    var body: some View {
        FormSection(title: "VPN 适配器",
                    footer: "修改适配器目录中的文件后，约一个本机检查间隔内自动生效。") {
            FormRow(label: loadedText, badge: "立即生效") {
                Button("重新加载") { model.reloadAdapters() }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .help("重新读取适配器目录，并立即做一次本机检查。")
            }
            ForEach(Array(model.adapterSet.problems.enumerated()), id: \.offset) { _, problem in
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(Typography.caption)
                    .foregroundColor(StatusTone.warning.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .rowPadding()
            }
        }
    }
}
