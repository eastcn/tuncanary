import SwiftUI
import TunCanaryCore

/// 一张状态卡：结论常显，证据可以展开查看。
struct StatusCardView: View {
    let card: StatusCard
    let expanded: Bool
    let toggle: () -> Void
    /// DNS 未恢复时在提示后附“恢复步骤”入口。
    var showRecoveryLink = false
    var openRecovery: () -> Void = {}
    var timeZone: TimeZone = .current

    private var tone: StatusTone { StatusTone(card.severity) }

    /// 证据：卡片证据之后附守护进程的情况。未安装时只在这里出现，不占卡片正文。
    private var evidence: [String] {
        guard let summary = card.dnsGuard else { return card.evidence }
        if !summary.installed && summary.failureReason == nil { return card.evidence + [summary.statusText] }
        return card.evidence + summary.recentEvents.map {
            "守护进程事件 \(DateText.format($0.date, timeZone: timeZone))：\($0.text)"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            SeverityBadge(severity: card.severity, size: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(card.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !evidence.isEmpty {
                        Button(action: toggle) {
                            HStack(spacing: 3) {
                                Text(expanded ? "收起" : "证据 \(evidence.count)")
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .rotationEffect(.degrees(expanded ? 180 : 0))
                            }
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(expanded ? "收起\(card.title)证据" : "展开\(card.title)证据"))
                    }
                }
                Text(card.conclusion)
                    .font(.system(size: 12))
                    .foregroundColor(card.severity == .ok ? .secondary : tone.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = card.hint {
                    Text("提示：\(hint)")
                        .font(.system(size: 11.5))
                        .foregroundColor(card.severity == .ok ? .secondary : .primary.opacity(0.85))
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
                    .padding(.top, 1)
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
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 3)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(tone)
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
