import SwiftUI
import TunCanaryCore

/// 设置 · 代理与 DNS：代理客户端、DNS 规则、探针域名。
struct SettingsProxyDNSTab: View {
    @ObservedObject var model: AppModel
    let validation: SettingsDraft.Validation

    var body: some View {
        ProxyClientSection(model: model, validation: validation)
        DNSRulesSection(model: model, error: validation.expectedDNSError)
        VStack(alignment: .leading, spacing: 6) {
            FormSection(title: "探针") {
                FormFieldRow(
                    label: "探针域名",
                    placeholder: PulseConstants.canaryHost,
                    text: $model.settingsDraft.canaryHost,
                    caption: "须是会分配 fake-ip 的域名。",
                    error: validation.canaryHostError)
            }
            NotesDisclosure(notes: [
                "用系统解析器查询这个域名，判断 DNS 是否经过代理。不能在代理的 fake-ip 过滤名单中。",
            ])
        }
    }
}

/// 代理客户端：Clash Verge Rev 读取配置文件；其他客户端手动填写 fake-ip 网段等参数。
struct ProxyClientSection: View {
    @ObservedObject var model: AppModel
    let validation: SettingsDraft.Validation

    private var isManual: Bool { model.settingsDraft.proxyClient == .manual }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FormSection(title: "代理客户端") {
                FormRow(label: "客户端") {
                    Picker("客户端", selection: $model.settingsDraft.proxyClient) {
                        ForEach(ProxyClientKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if isManual {
                    FormRow(label: "fake-ip 网段",
                            caption: "与代理配置中的 fake-ip-range 一致。",
                            error: validation.manualFakeIPRangeError) {
                        CompactField(label: "fake-ip 网段", placeholder: ManualProxyConfig.defaultFakeIPRange,
                                     text: $model.settingsDraft.manualFakeIPRange, width: 150,
                                     hasError: validation.manualFakeIPRangeError != nil)
                    }
                    FormRow(label: "代理 DNS 端口",
                            caption: "代理在本机监听的 DNS 端口，留空表示不检测。",
                            error: validation.manualDNSPortError) {
                        CompactField(label: "代理 DNS 端口", placeholder: "1053",
                                     text: $model.settingsDraft.manualDNSPort,
                                     hasError: validation.manualDNSPortError != nil)
                    }
                    FormRow(label: "核心进程名",
                            caption: "可执行文件名，留空表示不检查进程。",
                            error: validation.manualProcessNameError) {
                        CompactField(label: "核心进程名", placeholder: "mihomo",
                                     text: $model.settingsDraft.manualProcessName, width: 120,
                                     hasError: validation.manualProcessNameError != nil)
                    }
                } else {
                    FormRow(label: "站点失败时诊断代理",
                            caption: "只读，不修改代理配置，不需要 secret。") {
                        SettingsSwitch(label: "站点失败时诊断代理",
                                       isOn: $model.settingsDraft.proxyDiagnosticsEnabled)
                    }
                }
            }
            NotesDisclosure(notes: isManual ? [
                "TUN 是否运行按 fake-ip 网段内的接口判断。",
                "填写核心进程名后，进程未运行时判为 TUN 未生效。",
            ] : [
                "读取 Clash Verge Rev 的配置文件，只取 TUN 开关、DNS 端口、IPv6 开关和 fake-ip 网段，不读取 secret 和节点。",
                "站点诊断：站点访问失败时复测一次，同时通过 Clash Verge Rev 的本机控制接口读取代理日志，查看这次访问命中的规则和节点，并对节点测一次延迟。首次失败和失败类型变化时自动诊断，站点行上也可以手动诊断。",
            ])
        }
    }
}

/// DNS 规则：VPN 断开、TUN 运行时和 VPN 连接时，主网络保存的 DNS 应满足的条件。
struct DNSRulesSection: View {
    @ObservedObject var model: AppModel
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FormSection(title: "DNS 规则", footer: "检查主网络保存的 DNS。") {
                FormRow(label: "VPN 断开、TUN 运行时") {
                    Picker("VPN 断开、TUN 运行时", selection: $model.settingsDraft.disconnectedDNSRule) {
                        ForEach(DisconnectedDNSRule.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if model.settingsDraft.disconnectedDNSRule == .equals || error != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        FormRow(label: "预期 DNS",
                                caption: "一个或多个 IPv4 地址，用逗号分隔，比较时忽略顺序。",
                                error: error) {
                            CompactField(label: "预期 DNS", placeholder: "223.5.5.5",
                                         text: $model.settingsDraft.expectedDNS, width: 170,
                                         hasError: error != nil)
                        }
                        if let current = model.learnableExpectedDNS {
                            Button("用当前值作为预期（\(current.joined(separator: ", "))）") { model.adoptCurrentDNSAsExpected() }
                                .buttonStyle(PillButtonStyle(compact: true))
                                .help("当前系统解析经过代理，可以把此刻保存的 DNS 作为断开后的预期值。保存后生效。")
                                .padding(.horizontal, PopoverMetrics.rowHorizontal)
                                .padding(.bottom, PopoverMetrics.rowVertical)
                        }
                    }
                }
                FormRow(label: "VPN 连接时") {
                    Picker("VPN 连接时", selection: $model.settingsDraft.connectedDNSRule) {
                        ForEach(ConnectedDNSRule.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                FormRow(label: "TUN 关闭时，提示仍残留的预期 DNS") {
                    SettingsSwitch(label: "TUN 关闭时，提示仍残留的预期 DNS",
                                   isOn: $model.settingsDraft.residualDNSWarning)
                        .disabled(model.settingsDraft.disconnectedDNSRule != .equals)
                }
            }
            NotesDisclosure(notes: [
                "TUN 以 fake-ip 模式运行时，系统解析返回真实地址即判为故障，不需要配置。以上规则检查主网络保存的 DNS。",
                "“VPN 连接时”选“由代理接管”：VPN 连接、TUN 运行时，也按断开时的规则检查保存的 DNS，并要求系统解析返回 fake-ip。VPN 域名须由代理解析，VPN 站点探测失败通常说明代理没能解析 VPN 域名。",
                "“提示仍残留的预期 DNS”仅在断开时规则为“指定地址”时可用。",
            ])
        }
    }
}
