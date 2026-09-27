import SwiftUI
import TunCanaryCore

/// 本机状态的一行：正常时标题与结论排成一行；非正常时结论、提示和恢复入口另起一行完整显示。
/// 点整行展开或收起证据。
struct StatusRowView: View {
    let card: StatusCard
    let expanded: Bool
    let toggle: () -> Void
    /// DNS 未恢复时在提示后附“恢复步骤”入口。
    var showRecoveryLink = false
    var openRecovery: () -> Void = {}
    var timeZone: TimeZone = .current

    private var tone: StatusTone { StatusTone(card.severity) }
    private var isOK: Bool { card.severity == .ok }

    /// 证据：卡片证据之后附守护进程的情况。未安装时只在这里出现，不占正文。
    private var evidence: [String] {
        guard let summary = card.dnsGuard else { return card.evidence }
        if !summary.installed && summary.failureReason == nil { return card.evidence + [summary.statusText] }
        return card.evidence + summary.recentEvents.map {
            "守护进程事件 \(DateText.format($0.date, timeZone: timeZone))：\($0.text)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 8) {
                    SeverityBadge(severity: card.severity, size: 14)
                    Text(card.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .layoutPriority(2)
                    Spacer(minLength: 6)
                    if isOK {
                        Text(card.conclusion)
                            .font(Typography.body)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(card.conclusion)
                    }
                    if !evidence.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .frame(width: 10)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(evidence.isEmpty)
            .accessibilityLabel(Text("\(card.title)，\(card.severity.displayName)，\(card.conclusion)"))
            .accessibilityHint(Text(evidence.isEmpty ? "" : (expanded ? "收起证据" : "展开证据")))

            VStack(alignment: .leading, spacing: 3) {
                if !isOK {
                    Text(card.conclusion)
                        .font(Typography.body)
                        .foregroundColor(tone.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let hint = card.hint {
                    Text("提示：\(hint)")
                        .font(Typography.caption)
                        .foregroundColor(isOK ? .secondary : .primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showRecoveryLink {
                    Button(action: openRecovery) {
                        HStack(spacing: 3) {
                            Text("按手动恢复步骤处理")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Color(nsColor: StatusPalette.accent))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let summary = card.dnsGuard, summary.installed || summary.failureReason != nil {
                    DNSGuardLines(summary: summary, timeZone: timeZone)
                        .padding(.top, 2)
                }
                if expanded && !evidence.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text("·")
                                Text(item)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 1)
                }
            }
            .padding(.leading, 22)
        }
        .rowPadding()
        .background(isOK ? Color.clear : tone.cardFill)
        .accessibilityElement(children: .contain)
    }
}

/// 守护进程的情况：与卡片结论分开，用分隔线和独立的颜色，避免和 TunCanary 的判定混在一起。
struct DNSGuardLines: View {
    let summary: DNSGuardSummary
    let timeZone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider()
                .padding(.bottom, 2)
            Text(summary.statusText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.secondary)
            if let text = summary.lastRunText(timeZone: timeZone) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    SeverityBadge(severity: summary.lastRunSeverity, size: 11)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
            }
            if let text = summary.lastWriteText(timeZone: timeZone) {
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(summary.notices.enumerated()), id: \.offset) { _, notice in
                Text("注意：\(notice)")
                    .font(.system(size: 11.5))
                    .foregroundColor(StatusTone.warning.textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
