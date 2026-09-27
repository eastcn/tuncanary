import SwiftUI
import TunCanaryCore

/// 主页“出口 IP”分节：每个检测目标一行，只在用户点“检测”时访问，不轮询、不保存结果。
struct EgressIPSection: View {
    @ObservedObject var model: AppModel

    private var targets: [EgressIPTarget] { model.settings.effectiveEgressTargets }

    /// 最近一次检测的时间。
    private var checkedText: String? {
        guard let date = model.egressResults.map(\.checkedAt).max() else { return nil }
        return PopoverFormatter.clockText(date, now: model.now(), timeZone: model.timeZone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                SectionTitle(title: "出口 IP", trailing: model.isCheckingEgress ? "检测中…" : checkedText)
                if model.isCheckingEgress {
                    Button("取消") { model.cancelEgressIP() }
                        .buttonStyle(PillButtonStyle(compact: true))
                } else {
                    Button(model.egressResults.isEmpty ? "检测" : "重新检测") { model.checkEgressIP() }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .disabled(model.egressChecker == nil)
                        .help("访问各目标的 /cdn-cgi/trace，查看本应用到该目标的出口")
                }
            }
            .padding(.leading, 2)
            GroupCard {
                ForEach(targets, id: \.self) { target in
                    EgressTargetRow(target: target,
                                    result: model.egressResults.first { $0.target == target },
                                    isChecking: model.isCheckingEgress)
                }
            }
        }
    }
}

/// 一个出口检测目标：名称与 IP 同一行，版本与归属地在名称下方。
struct EgressTargetRow: View {
    let target: EgressIPTarget
    let result: EgressIPResult?
    let isChecking: Bool

    /// 自定义目标常见的失败原因：站点不经 Cloudflare，没有 trace 地址。
    private var failureText: String? {
        guard let result, result.ip == nil else { return nil }
        let text = result.failure?.displayName ?? "未取得结果"
        guard !target.isBuiltIn else { return text }
        switch result.failure {
        case .httpStatus, .invalidResponse, .missingIP, .redirect:
            return "\(text)，可能不经 Cloudflare"
        default:
            return text
        }
    }

    private var subtitle: String? {
        guard let result, result.ip != nil else { return target.isBuiltIn ? nil : target.host }
        let parts = [result.ipVersion?.displayName, result.location].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(target.displayName)
                    .font(Typography.rowTitle)
                    .lineLimit(1)
                if let subtitle, target.displayName != subtitle {
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            Group {
                if let ip = result?.ip {
                    Text(ip)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(ip)
                } else if let failureText {
                    Text(failureText)
                        .font(Typography.caption)
                        .foregroundColor(StatusTone.warning.textColor)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(isChecking ? "检测中…" : PopoverFormatter.noValue)
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .rowPadding()
        .accessibilityElement(children: .combine)
    }
}
