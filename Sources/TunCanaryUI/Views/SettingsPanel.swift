import SwiftUI
import TunCanaryCore

/// 设置页：检测频率、公开站点、内网站点、DNS 与系统选项。
struct SettingsPanel: View {
    @ObservedObject var model: AppModel
    let maxScrollHeight: CGFloat?

    var body: some View {
        let validation = model.settingsValidation
        VStack(spacing: 0) {
            PanelNavBar(title: "设置") { model.showMain() }
            Divider()
            BoundedScroll(maxHeight: maxScrollHeight) {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsTextField(
                        title: "内网站点 URL",
                        placeholder: "https://intranet.example.com/",
                        text: $model.settingsDraft.intranetURL,
                        caption: "必须是 http 或 https，且含主机名。留空表示未配置，内网站点显示“未验证”。诊断摘要只显示“已配置”或“未配置”。",
                        error: validation.intranetURLError)
                    ProxyClientSection(model: model, validation: validation)
                    DNSRulesSection(model: model, error: validation.expectedDNSError)
                    SettingsTextField(
                        title: "探针域名",
                        placeholder: PulseConstants.canaryHost,
                        text: $model.settingsDraft.canaryHost,
                        caption: "用系统解析器查询这个域名，判断 DNS 是否经过代理。须是会分配 fake-ip 的域名，不能在代理的 fake-ip 过滤名单中。",
                        error: validation.canaryHostError)
                    SettingsTextField(
                        title: "本机检查间隔（秒）",
                        placeholder: "20",
                        text: $model.settingsDraft.localCheckInterval,
                        caption: "默认 20 秒；可设置 5–3600 秒。",
                        error: validation.localCheckIntervalError)
                    SettingsTextField(
                        title: "后台站点检测间隔（秒）",
                        placeholder: "120",
                        text: $model.settingsDraft.lightProbeInterval,
                        caption: "默认 120 秒；可设置 15–86400 秒。检测未结束时会合并触发，避免重叠请求。",
                        error: validation.lightProbeIntervalError)
                    VPNAdaptersSection(model: model)
                    PublicSitesSettingsSection(model: model, validation: validation)
                    CheckPagesSection(model: model, validation: validation)
                    NotificationSettingsSection(model: model)
                    LoginItemSection(model: model)
                }
                .padding(PopoverMetrics.padding)
            }
            Divider()
            HStack(spacing: 8) {
                if model.showsSavedFeedback {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(StatusTone.ok.textColor)
                } else if !validation.isValid {
                    Text("请先修正标红的项")
                        .font(.system(size: 11.5))
                        .foregroundColor(StatusTone.critical.textColor)
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

/// 分节标题。
private struct SettingsHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12.5, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

/// 文本输入 + 说明；有错误时在输入框下方显示错误（替代说明）。
struct SettingsTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let caption: String?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SettingsHeading(title: title)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
                .accessibilityLabel(Text(title))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(StatusTone.critical.markColor, lineWidth: error == nil ? 0 : 1.2)
                        .allowsHitTesting(false))
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundColor(StatusTone.critical.textColor)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 代理客户端：Clash Verge Rev 读取配置文件；其他客户端手动填写 fake-ip 网段等参数。
struct ProxyClientSection: View {
    @ObservedObject var model: AppModel
    let validation: SettingsDraft.Validation

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsHeading(title: "代理客户端")
            Picker("客户端", selection: $model.settingsDraft.proxyClient) {
                ForEach(ProxyClientKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .font(.system(size: 12.5))
            if model.settingsDraft.proxyClient == .manual {
                Group {
                    SettingsTextField(
                        title: "fake-ip 网段",
                        placeholder: ManualProxyConfig.defaultFakeIPRange,
                        text: $model.settingsDraft.manualFakeIPRange,
                        caption: "与代理配置中的 fake-ip-range 一致。TUN 是否运行按此网段内的接口判断。",
                        error: validation.manualFakeIPRangeError)
                    SettingsTextField(
                        title: "代理 DNS 端口",
                        placeholder: "留空表示不检测",
                        text: $model.settingsDraft.manualDNSPort,
                        caption: "代理在本机监听的 DNS 端口，例如 1053。",
                        error: validation.manualDNSPortError)
                    SettingsTextField(
                        title: "核心进程名",
                        placeholder: "留空表示不检查进程",
                        text: $model.settingsDraft.manualProcessName,
                        caption: "可执行文件名，例如 mihomo。填写后，进程未运行时判为 TUN 未生效。",
                        error: validation.manualProcessNameError)
                }
                .padding(.leading, 14)
            } else {
                Text("读取 Clash Verge Rev 的配置文件，只取 TUN 开关、DNS 端口、IPv6 开关和 fake-ip 网段，不读取 secret 和节点。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// DNS 规则：VPN 断开、TUN 运行时和 VPN 连接时，主网络保存的 DNS 应满足的条件。
struct DNSRulesSection: View {
    @ObservedObject var model: AppModel
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsHeading(title: "DNS 规则")
            Text("TUN 以 fake-ip 模式运行时，系统解析返回真实地址即判为故障，不需要配置。以下规则检查主网络保存的 DNS。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("VPN 断开、TUN 运行时", selection: $model.settingsDraft.disconnectedDNSRule) {
                ForEach(DisconnectedDNSRule.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .font(.system(size: 12.5))
            if model.settingsDraft.disconnectedDNSRule == .equals || error != nil {
                SettingsTextField(
                    title: "预期 DNS",
                    placeholder: "223.5.5.5",
                    text: $model.settingsDraft.expectedDNS,
                    caption: "一个或多个 IPv4 地址，用逗号分隔，比较时忽略顺序。",
                    error: error)
                    .padding(.leading, 14)
            }
            if let current = model.learnableExpectedDNS {
                Button("用当前值作为预期（\(current.joined(separator: ", "))）") { model.adoptCurrentDNSAsExpected() }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .help("当前系统解析经过代理，可以把此刻保存的 DNS 作为断开后的预期值。保存后生效。")
            }
            Picker("VPN 连接时", selection: $model.settingsDraft.connectedDNSRule) {
                ForEach(ConnectedDNSRule.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .font(.system(size: 12.5))
            if model.settingsDraft.connectedDNSRule == .proxyTakeover {
                Text("VPN 连接、TUN 运行时，也按上面的规则检查保存的 DNS，并要求系统解析返回 fake-ip。内网域名须由代理解析，内网站点探测失败通常说明代理没能解析内网域名。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
            }
            Toggle(isOn: $model.settingsDraft.residualDNSWarning) {
                Text("TUN 关闭时，提示仍残留的预期 DNS")
                    .font(.system(size: 12.5))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(model.settingsDraft.disconnectedDNSRule != .equals)
        }
    }
}

/// VPN 适配器：显示已加载的适配器和无效文件，可以立即重新读取目录（不随“保存”）。
struct VPNAdaptersSection: View {
    @ObservedObject var model: AppModel

    private var loadedText: String {
        let adapters = model.adapterSet.adapters
        guard !adapters.isEmpty else { return "未加载适配器。" }
        return "已加载 \(adapters.count) 个：\(adapters.map(\.name).joined(separator: "、"))。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsHeading(title: "VPN 适配器")
            Text("\(loadedText)修改适配器目录中的文件后，约一个本机检查间隔内自动生效。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(model.adapterSet.problems.enumerated()), id: \.offset) { _, problem in
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundColor(StatusTone.warning.textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("立即重新加载") { model.reloadAdapters() }
                .buttonStyle(PillButtonStyle(compact: true))
                .help("重新读取适配器目录，并立即做一次本机检查。")
        }
    }
}

/// 外部检测页与出口检测目标。
struct CheckPagesSection: View {
    @ObservedObject var model: AppModel
    let validation: SettingsDraft.Validation

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsHeading(title: "检测页与出口")
            Text("检测页在浏览器中打开，最多 \(AppSettings.maxCheckPages) 个，显示在弹窗底部。第三方检测页会看到你的出口 IP，请自行判断是否可信。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach($model.settingsDraft.checkPages) { $page in
                let pageID = page.id
                let index = model.settingsDraft.checkPages.firstIndex { $0.id == pageID }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TextField("名称", text: $page.name)
                            .frame(width: 90)
                        TextField("https://…", text: $page.url)
                        Button {
                            model.settingsDraft.checkPages.removeAll { $0.id == pageID }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("删除此检测页")
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    if let error = index.flatMap({ validation.checkPageErrors[$0] }) {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundColor(StatusTone.critical.textColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button("添加检测页") { model.settingsDraft.checkPages.append(SettingsDraft.CheckPageDraft()) }
                .buttonStyle(PillButtonStyle(compact: true))
                .disabled(model.settingsDraft.checkPages.count >= AppSettings.maxCheckPages)
            Toggle(isOn: $model.settingsDraft.egressIncludesClaude) {
                Text("“检测出口”同时访问 claude.ai")
                    .font(.system(size: 12.5))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}

/// 通知开关与系统授权状态。
struct NotificationSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsHeading(title: "通知")
            Toggle(isOn: $model.settingsDraft.notificationsEnabled) {
                Text("出现需关注或故障时发送系统通知")
                    .font(.system(size: 12.5))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            status
            Text("同一故障只通知一次，同一轮的多条通知合并为一条；恢复和“未确认”不通知。通知内容不包含内网站点 URL。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var status: some View {
        if !model.notificationsAvailable {
            CalloutBox(tone: .neutral, icon: "bell.slash", title: "系统通知不可用",
                       detail: "当前未在应用包内运行（例如 swift run），不会发送系统通知。")
        } else {
            switch model.notificationAuthorization {
            case .denied:
                CalloutBox(tone: .warning, icon: "bell.slash.fill", title: "系统通知已关闭",
                           detail: "菜单栏和弹窗仍正常工作；需要通知时请在系统设置中允许 TunCanary。") {
                    Button("打开系统设置") { model.openNotificationSettings() }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .padding(.top, 2)
                }
            case .notDetermined:
                CalloutBox(tone: .neutral, icon: "bell", title: "尚未授权系统通知") {
                    Button("允许通知") { Task { await model.requestNotificationPermission() } }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .padding(.top, 2)
                }
            case .authorized:
                Label("系统通知已允许", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundColor(StatusTone.ok.textColor)
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
        VStack(alignment: .leading, spacing: 7) {
            SettingsHeading(title: "登录时启动")
            Toggle(isOn: isOn) {
                Text("登录时自动启动 TunCanary")
                    .font(.system(size: 12.5))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!isAppBundle)
            Text("系统状态：\(model.loginItemStatus.displayName)。此开关立即生效。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            switch model.loginItemStatus {
            case .requiresApproval:
                CalloutBox(tone: .warning, icon: "exclamationmark.triangle.fill", title: "需要在系统设置中批准",
                           detail: "请在“系统设置 → 通用 → 登录项”中允许 TunCanary，登录时启动才会生效。") {
                    Button("打开登录项设置") { model.openLoginItemSettings() }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .padding(.top, 2)
                }
            case .unavailable:
                if isAppBundle {
                    CalloutBox(tone: .warning, icon: "exclamationmark.triangle.fill", title: "登录项状态不可用",
                               detail: "可尝试打开上方开关重新注册。若仍无法启用，请查看错误信息并检查系统设置中的登录项。") {
                        Button("打开登录项设置") { model.openLoginItemSettings() }
                            .buttonStyle(PillButtonStyle(compact: true))
                            .padding(.top, 2)
                    }
                } else {
                    CalloutBox(tone: .neutral, icon: "info.circle", title: "登录时启动不可用",
                               detail: "仅在安装后的应用包中可用；当前运行环境不会调用系统登录项接口。")
                }
            case .enabled, .disabled:
                EmptyView()
            }
            if let error = model.loginItemError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundColor(StatusTone.critical.textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
