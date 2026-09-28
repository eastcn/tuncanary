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
