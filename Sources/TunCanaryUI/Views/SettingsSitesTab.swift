import SwiftUI
import TunCanaryCore

/// 设置 · 站点：公开站点、VPN 站点与 Tailnet 子网、出口检测目标、检测页。
struct SettingsSitesTab: View {
    @ObservedObject var model: AppModel
    let validation: SettingsDraft.Validation

    var body: some View {
        PublicSitesSettingsSection(model: model, validation: validation)

        VStack(alignment: .leading, spacing: 6) {
            FormSection(title: "VPN 与 Tailnet") {
                FormFieldRow(
                    label: "VPN 站点 URL",
                    placeholder: "https://intranet.example.com/",
                    text: $model.settingsDraft.intranetURL,
                    caption: "留空表示未配置，VPN 站点显示“未验证”。",
                    error: validation.intranetURLError)
                FormFieldRow(
                    label: "Tailnet 子网目标",
                    placeholder: "192.168.1.10:443",
                    text: $model.settingsDraft.tailnetTarget,
                    caption: "子网里一台常开设备的 IPv4 地址和 TCP 端口，留空表示未配置。",
                    error: validation.tailnetTargetError)
            }
            NotesDisclosure(notes: [
                "VPN 站点 URL 必须是 http 或 https，且含主机名。诊断摘要只显示“已配置”或“未配置”。",
                "Tailnet 子网目标：经 Tailscale 子网路由访问时做连接探测，连续三轮失败判为故障；端口拒绝连接也算可达。当前网络与 Tailnet 子网网段相同时不探测。",
            ])
        }

        EgressTargetsSection(model: model, validation: validation)
        CheckPagesSection(model: model, validation: validation)
    }
}

/// 出口检测目标：内置 Cloudflare（始终检测）、Claude、ChatGPT、淘宝（可选），以及自定义域名。
/// 每个目标一行，名称与域名在左、操作在右；新域名在底部输入，校验通过后才加入列表。
struct EgressTargetsSection: View {
    @ObservedObject var model: AppModel
    let validation: SettingsDraft.Validation
    @State private var newHost = ""
    @State private var addError: String?

    private var customCount: Int { model.settingsDraft.customEgressHosts.count }
    private var isFull: Bool { customCount >= EgressIPTarget.maxCustom }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FormSection(title: "出口检测目标",
                        trailing: "自定义 \(customCount) / \(EgressIPTarget.maxCustom)",
                        footer: "只在主页点“检测”时访问，不定时检测，不保存结果。") {
                FormRow(label: EgressIPTarget.cloudflare.displayName, caption: EgressIPTarget.cloudflare.host) {
                    Text("始终检测")
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(EgressIPTarget.builtIns.filter { $0 != .cloudflare }, id: \.self) { target in
                    FormRow(label: target.displayName, caption: caption(target)) {
                        SettingsSwitch(label: "检测\(target.displayName)出口", isOn: binding(target))
                    }
                }
                ForEach(Array(model.settingsDraft.customEgressHosts.enumerated()), id: \.element.id) { index, draft in
                    FormRow(label: draft.host, caption: "自定义域名", error: validation.egressHostErrors[index]) {
                        Button {
                            model.settingsDraft.customEgressHosts.removeAll { $0.id == draft.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("删除 \(draft.host)")
                    }
                }
                if !isFull {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            TextField("添加域名，例如 chatgpt.com", text: $newHost)
                                .textFieldStyle(.roundedBorder)
                                .font(Typography.rowTitle)
                                .accessibilityLabel(Text("新的出口检测域名"))
                                .errorOutline(addError != nil)
                                .onSubmit(add)
                                .onChange(of: newHost) { _ in addError = nil }
                            Button("添加", action: add)
                                .buttonStyle(PillButtonStyle(compact: true))
                                .disabled(newHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let addError { ErrorText(text: addError) }
                    }
                    .rowPadding()
                }
            }
            NotesDisclosure(notes: [
                "每个目标访问 https://<域名>/cdn-cgi/trace，由目标回显本应用请求的出口 IP 和归属地。代理按域名分流时，不同目标可能看到不同的出口。",
                "淘宝不经 Cloudflare，改为查询淘宝 IP 库（ip.taobao.com），可以看到国内站点走的出口。这是非公开接口，有频率限制，也可能失效；失败时只影响这一行。",
                "自定义域名只对经 Cloudflare 的站点有效；其他站点会显示失败。可以填域名，也可以粘贴网址，只取其中的主机名。",
            ])
        }
    }

    private func caption(_ target: EgressIPTarget) -> String {
        target == .taobao ? "\(target.host) · 淘宝 IP 库接口" : target.host
    }

    private func binding(_ target: EgressIPTarget) -> Binding<Bool> {
        Binding(get: { model.settingsDraft.enabledEgressBuiltIns.contains(target) },
                set: { model.settingsDraft.setEgressBuiltIn(target, enabled: $0) })
    }

    private func add() {
        addError = model.settingsDraft.addEgressHost(newHost)
        if addError == nil { newHost = "" }
    }
}

/// 外部检测页。
struct CheckPagesSection: View {
    @ObservedObject var model: AppModel
    let validation: SettingsDraft.Validation

    var body: some View {
        FormSection(title: "检测页",
                    trailing: "\(model.settingsDraft.checkPages.count) / \(AppSettings.maxCheckPages)",
                    footer: "检测页在浏览器中打开，显示在主页底部。第三方检测页会看到你的出口 IP，请自行判断是否可信。") {
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
                    .font(Typography.body)
                    if let error = index.flatMap({ validation.checkPageErrors[$0] }) {
                        ErrorText(text: error)
                    }
                }
                .rowPadding()
            }
            HStack {
                Button("添加检测页") { model.settingsDraft.checkPages.append(SettingsDraft.CheckPageDraft()) }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .disabled(model.settingsDraft.checkPages.count >= AppSettings.maxCheckPages)
                Spacer()
            }
            .rowPadding()
        }
    }
}
