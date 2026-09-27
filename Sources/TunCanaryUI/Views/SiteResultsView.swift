import SwiftUI
import TunCanaryCore

/// 一个站点分组：组名 + 站点行。
struct SiteGroupView: View {
    let group: SiteGroupPresentation
    var onDiagnose: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(group.title)
                .font(Typography.caption.weight(.medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 2)
                .accessibilityAddTraits(.isHeader)
            if group.rows.isEmpty {
                GroupCard {
                    Text("本组暂无已启用公开站点")
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                        .rowPadding()
                }
            } else {
                GroupCard {
                    ForEach(group.rows) { row in
                        SiteRowView(row: row, onDiagnose: { onDiagnose(row.id) })
                    }
                }
            }
        }
    }
}

/// 站点行的固定列宽，保证各行的状态、延迟、圆点和操作列对齐。
enum SiteRowMetrics {
    static let status: CGFloat = 62
    static let latency: CGFloat = 50
    static let action: CGFloat = 36
}

/// 一个站点：名称、可达性类别、延迟中位数、最近 5 次结果、诊断排成一行；
/// 错误原因与 VPN 站点说明另起一行，悬停提示也保留相同信息。
/// “诊断”在失败、诊断中或已有结果时常显，其余情况悬停时才显示。
struct SiteRowView: View {
    let row: SiteRowPresentation
    var onDiagnose: () -> Void = {}
    @State private var hovering = false

    private var showsDiagnose: Bool {
        guard row.canDiagnose else { return false }
        return hovering || row.isDiagnosing || !row.diagnosisLines.isEmpty ||
            row.tone == .warning || row.tone == .critical
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 6) {
                HStack(spacing: 4) {
                    Text(row.name)
                        .font(Typography.rowTitle)
                        .lineLimit(1)
                    if row.isKey { TagLabel(text: "关键") }
                }
                .layoutPriority(2)
                Spacer(minLength: 4)
                Text(row.statusText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(row.tone.textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(minWidth: SiteRowMetrics.status, alignment: .trailing)
                Text(row.latencyText)
                    .font(Typography.body.monospacedDigit())
                    .foregroundColor(row.latencyText == PopoverFormatter.noValue ? .secondary.opacity(0.7) : .primary.opacity(0.85))
                    .frame(width: SiteRowMetrics.latency, alignment: .trailing)
                HistoryDots(marks: row.history)
                Group {
                    if showsDiagnose {
                        Button(row.isDiagnosing ? "诊断中" : "诊断", action: onDiagnose)
                            .buttonStyle(.link)
                            .font(Typography.caption)
                            .disabled(row.isDiagnosing)
                            .help("复测一次，并从代理日志查看这次访问命中的规则和节点")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: SiteRowMetrics.action, height: 14, alignment: .trailing)
            }
            if let detail = row.detailText {
                Text(detail)
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !row.diagnosisLines.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(row.diagnosisLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, weight: index == 0 ? .medium : .regular))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 8)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, PopoverMetrics.rowHorizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(row.detailText ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(([row.accessibilityText] + row.diagnosisLines).joined(separator: "，")))
    }
}

/// 最近 5 次结果：实心圆点按色调着色，空位为空心圆。
struct HistoryDots: View {
    let marks: [HistoryMark]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                Group {
                    if mark.isEmpty {
                        Circle()
                            .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
                    } else {
                        Circle()
                            .fill(mark.tone.markColor)
                    }
                }
                .frame(width: 7, height: 7)
                .help(mark.label)
            }
        }
        .accessibilityHidden(true)
    }
}
