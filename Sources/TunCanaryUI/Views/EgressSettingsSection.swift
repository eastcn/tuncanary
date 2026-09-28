import SwiftUI
import TunCanaryCore

struct EgressSheetTarget: Identifiable {
    let target: EgressIPTarget
    var id: String { target.rawValue }
}

/// 内置和自定义目标共用监测、地域规则和历史；端点身份包含实际 URL 与提取方式。
struct EgressTargetsSection: View {
    @ObservedObject var model: AppModel
    let validation: SettingsDraft.Validation
    @State private var newHost = ""
    @State private var addError: String?
    @State private var endpointMode = false
    @State private var endpointName = ""
    @State private var endpointURL = ""
    @State private var endpointMethod: EgressEndpoint.Method = .header
    @State private var endpointSelector = ""
    @State private var regionTarget: EgressSheetTarget?

    private var customCount: Int { model.settingsDraft.customEgressHosts.count }
    private var isFull: Bool { customCount >= EgressIPTarget.maxCustom }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FormSection(title: "出口稳定性监测", footer: "历史在本机保留 30 天。地域按实测 IP 查询 ipwho.is，缓存 7 天；查询会向该服务发送出口 IP。") {
                FormRow(label: "自动检测", caption: "应用运行且系统唤醒时检测；淘宝 IP 库仅手动") {
                    SettingsSwitch(label: "自动检测出口", isOn: $model.settingsDraft.egressAutomatic)
                }
                FormFieldRow(label: "检测间隔（分钟）", placeholder: "5", text: $model.settingsDraft.egressIntervalMinutes,
                             caption: "5–1440 分钟；手动检测同样遵守间隔和限流冷却。", error: validation.egressMonitoringError)
                FormRow(label: "IP 变化通知", caption: "默认只记录；地域越界连续两次确认后通知，恢复再通知") {
                    SettingsSwitch(label: "IP 变化通知", isOn: $model.settingsDraft.egressNotifyIPChanges)
                }
            }
            FormSection(title: "出口检测目标", trailing: "自定义 \(customCount) / \(EgressIPTarget.maxCustom)",
                        footer: "实际请求域名与其他域名可能走不同出口。未配置允许地域时只记录变化。") {
                FormRow(label: EgressIPTarget.cloudflare.displayName, caption: EgressIPTarget.cloudflare.host) {
                    Text("始终检测").font(Typography.caption).foregroundColor(.secondary)
                }
                ForEach(EgressIPTarget.builtIns.filter { $0 != .cloudflare }, id: \.self) { target in
                    FormRow(label: target.displayName, caption: target.host) {
                        SettingsSwitch(label: "检测\(target.displayName)出口", isOn: binding(target))
                    }
                }
                ForEach(Array(model.settingsDraft.customEgressHosts.enumerated()), id: \.element.id) { index, draft in
                    FormRow(label: draft.method == nil ? draft.host : draft.name,
                            caption: draft.method == nil ? "Cloudflare trace" : "\(draft.host) · \(draft.selector)",
                            error: validation.egressHostErrors[index]) {
                        Button {
                            model.settingsDraft.customEgressHosts.removeAll { $0.id == draft.id }
                        } label: { Image(systemName: "minus.circle").foregroundColor(.secondary) }
                        .buttonStyle(.plain)
                        .help("删除此出口目标")
                    }
                }
                if !isFull { addFields }
            }
            FormSection(title: "允许的国家和地区", footer: "每个目标可多选。地域未知、查询过期或检测失败时不判为越界。") {
                ForEach(model.settingsDraft.draftEgressTargets, id: \.self) { target in
                    FormRow(label: target.displayName, caption: regionText(target)) {
                        Button("选择") { regionTarget = EgressSheetTarget(target: target) }
                            .buttonStyle(PillButtonStyle(compact: true))
                    }
                }
            }
        }
        .sheet(item: $regionTarget) { selected in
            EgressRegionPicker(target: selected.target, selection: Binding(
                get: { model.settingsDraft.egressAllowedRegions[selected.id] ?? [] },
                set: { model.settingsDraft.egressAllowedRegions[selected.id] = $0 }))
        }
    }

    private var addFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("添加自定义 HTTPS 回显接口", isOn: $endpointMode)
                .toggleStyle(.checkbox)
                .onChange(of: endpointMode) { _ in addError = nil }
            if endpointMode {
                TextField("名称", text: $endpointName)
                TextField("https://example.com/ip", text: $endpointURL)
                Picker("读取方式", selection: $endpointMethod) {
                    Text("响应头（HEAD）").tag(EgressEndpoint.Method.header)
                    Text("JSON 字段（GET）").tag(EgressEndpoint.Method.json)
                }
                TextField(endpointMethod == .header ? "响应头，例如 x-request-ip" : "字段路径，例如 data.ip", text: $endpointSelector)
                Button("添加回显接口", action: addEndpoint).buttonStyle(PillButtonStyle(compact: true))
            } else {
                HStack(spacing: 6) {
                    TextField("添加域名，例如 chatgpt.com", text: $newHost)
                        .accessibilityLabel(Text("新的出口检测域名"))
                        .onSubmit(addHost)
                        .onChange(of: newHost) { _ in addError = nil }
                    Button("添加", action: addHost).buttonStyle(PillButtonStyle(compact: true))
                        .disabled(newHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("域名需经 Cloudflare；普通网站需提供可回显 IP 的接口。")
                    .font(Typography.caption).foregroundColor(.secondary)
            }
            if let addError { ErrorText(text: addError) }
        }
        .textFieldStyle(.roundedBorder)
        .font(Typography.body)
        .rowPadding()
    }

    private func binding(_ target: EgressIPTarget) -> Binding<Bool> {
        Binding(get: { model.settingsDraft.enabledEgressBuiltIns.contains(target) },
                set: { model.settingsDraft.setEgressBuiltIn(target, enabled: $0) })
    }
    private func regionText(_ target: EgressIPTarget) -> String {
        let codes = model.settingsDraft.egressAllowedRegions[target.rawValue] ?? []
        return codes.isEmpty ? "未配置，只记录" : codes.sorted().map(EgressRegions.name).joined(separator: "、")
    }
    private func addHost() {
        addError = model.settingsDraft.addEgressHost(newHost)
        if addError == nil { newHost = "" }
    }
    private func addEndpoint() {
        let draft = SettingsDraft.EgressHostDraft(host: endpointURL.trimmingCharacters(in: .whitespacesAndNewlines),
            name: endpointName.trimmingCharacters(in: .whitespacesAndNewlines), method: endpointMethod,
            selector: endpointSelector.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let target = draft.target else { addError = "请填写名称、有效的 HTTPS URL 和响应头或 JSON 字段路径"; return }
        guard !model.settingsDraft.draftEgressTargets.contains(target) else { addError = "此接口已添加"; return }
        guard !isFull else { return }
        model.settingsDraft.customEgressHosts.append(draft)
        endpointName = ""; endpointURL = ""; endpointSelector = ""; addError = nil
    }
}

struct EgressRegionPicker: View {
    let target: EgressIPTarget
    @Binding var selection: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showAll = false
    private var codes: [String] {
        let candidates = showAll || !search.isEmpty ? EgressRegions.all : EgressRegions.common
        return candidates.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) || EgressRegions.name($0).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(target.displayName)：允许地域").font(.headline)
            TextField("搜索国家、地区或编码", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(codes, id: \.self) { code in
                        Toggle("\(EgressRegions.name(code))（\(code)）", isOn: Binding(
                            get: { selection.contains(code) },
                            set: { if $0 { selection.insert(code) } else { selection.remove(code) } }))
                        .toggleStyle(.checkbox)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !showAll { Button("更多国家和地区") { showAll = true } }
            Text(selection.isEmpty ? "未选择：只记录，不发送地域越界通知" : "已选择 \(selection.count) 项")
                .font(.caption).foregroundColor(.secondary)
            HStack { Button("清空") { selection = [] }; Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 400, height: 420)
    }
}
