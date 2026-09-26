import SwiftUI
import TunCanaryCore

/// 一个站点分组：组名 + 站点行。
struct SiteGroupView: View {
    let group: SiteGroupPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(group.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.primary.opacity(0.8))
                .accessibilityAddTraits(.isHeader)
            if group.rows.isEmpty {
                Text("本组暂无已启用公开站点")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground(.neutral)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, 10)
                        }
                        SiteRowView(row: row)
                    }
                }
                .cardBackground(.neutral)
            }
        }
    }
}

/// 一个站点：名称、可达性类别、延迟中位数、最近 5 次结果排成一行；
/// 错误原因与内网说明另起一行，悬停提示也保留相同信息。
struct SiteRowView: View {
    let row: SiteRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 4) {
                    Text(row.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    if row.isKey {
                        Text("关键")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 0.5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 0.6))
                    }
                }
                .layoutPriority(2)
                Spacer(minLength: 4)
                Text(row.statusText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(row.tone.textColor)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(row.latencyText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(row.latencyText == PopoverFormatter.noValue ? .secondary.opacity(0.7) : .primary.opacity(0.85))
                    .frame(minWidth: 50, alignment: .trailing)
                HistoryDots(marks: row.history)
            }
            if let detail = row.detailText {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .help(row.detailText ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(row.accessibilityText))
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
