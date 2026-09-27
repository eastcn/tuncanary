import SwiftUI
import TunCanaryCore

/// 可折叠的公开站点编辑器。所有操作只修改草稿，点击“保存”后才写入设置。
struct PublicSitesSettingsSection: View {
    @ObservedObject var model: AppModel
    let validation: SettingsDraft.Validation
    @State private var isExpanded = false

    private var enabledCount: Int { model.settingsDraft.sites.filter(\.isEnabled).count }

    private var availableGroups: [SiteGroup] {
        var groups: [SiteGroup] = [.mainland, .overseas]
        for site in model.settingsDraft.sites where site.group != .intranet &&
            !site.group.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !groups.contains(site.group) {
            groups.append(site.group)
        }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("公开站点")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("已启用 \(enabledCount) / \(model.settingsDraft.sites.count)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    if validation.siteCountError != nil || !validation.siteErrors.isEmpty {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(StatusTone.critical.textColor)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text("公开站点最多 20 个；未启用的站点保留在设置中，不参与检测。VPN 站点仍由上方 URL 和 VPN 状态单独控制。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = validation.siteCountError {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundColor(StatusTone.critical.textColor)
                }
                if model.settingsDraft.sites.isEmpty {
                    Text("没有公开站点；可添加站点或还原默认站点。")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }
                ForEach($model.settingsDraft.sites) { $site in
                    let editorID = site.editorID
                    let index = model.settingsDraft.sites.firstIndex { $0.editorID == editorID }
                    PublicSiteEditorRow(
                        site: $site,
                        availableGroups: availableGroups,
                        errors: index.flatMap { validation.siteErrors[$0] },
                        delete: { model.settingsDraft.sites.removeAll { $0.editorID == editorID } })
                }
                HStack(spacing: 8) {
                    Button("添加站点") { model.settingsDraft.addSite() }
                        .disabled(model.settingsDraft.sites.count >= 20)
                    Menu("添加常用站点") {
                        ForEach(model.settingsDraft.availableTemplates) { template in
                            Button("\(template.name)（\(template.group.displayName)）") {
                                model.settingsDraft.addTemplate(template)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.settingsDraft.sites.count >= 20 || model.settingsDraft.availableTemplates.isEmpty)
                    Button("还原默认站点") { model.settingsDraft.restoreDefaultSites() }
                    Spacer()
                }
                .buttonStyle(PillButtonStyle(compact: true))
                .padding(.top, 2)
            }
        }
    }
}

private struct PublicSiteEditorRow: View {
    @Binding var site: SettingsDraft.SiteDraft
    let availableGroups: [SiteGroup]
    let errors: SettingsDraft.SiteErrors?
    let delete: () -> Void
    @State private var isExpanded = false

    private var summary: String {
        let name = site.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "新站点" : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(summary).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if errors != nil {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(StatusTone.critical.textColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 2)
                Toggle("启用", isOn: $site.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11))
            }
            if isExpanded {
                SettingsTextField(title: "名称", placeholder: "站点名称", text: $site.name,
                                  caption: nil, error: errors?.name)
                if errors?.id != nil {
                    Label("站点配置已损坏，请删除后重新添加", systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundColor(StatusTone.critical.textColor)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("分组").font(.system(size: 12.5, weight: .semibold))
                    Picker("分组", selection: $site.group) {
                        ForEach(availableGroups, id: \.self) { group in
                            Text(group.displayName).tag(group)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("选择已有分组，或输入新组名", text: SettingsDraft.SiteDraft.groupFieldBinding($site))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5))
                        .accessibilityLabel(Text("分组名称"))
                    Text("直接输入已有组名可归入该组；VPN 站点在上方单独配置。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    if let error = errors?.group {
                        Text(error).font(.system(size: 11.5)).foregroundColor(StatusTone.critical.textColor)
                    }
                }
                SettingsTextField(title: "URL", placeholder: "https://example.com/", text: $site.url,
                                  caption: "http 或 https 地址，须含主机名，不可包含账号或密码。", error: errors?.url)
                Toggle("参与后台检测与故障告警", isOn: $site.inLightProbe)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12))
                Text("连续三轮失败会提示需关注；同组全部后台站点失败会判定故障。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("删除站点", action: delete)
                        .foregroundColor(StatusTone.critical.textColor)
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                }
            }
        }
        .padding(9)
        .cardBackground(.neutral)
    }
}

extension SettingsDraft.SiteDraft {
    /// 分组输入框绑定原始文本，保存时再映射为分组，避免输入到“japan”时被立即改写为“海外”。
    public static func groupFieldBinding(_ site: Binding<Self>) -> Binding<String> {
        site.groupText
    }
}
