import SwiftUI
import TunCanaryCore

/// 弹窗主页：总体状态、操作、四张状态卡、站点结果、工具入口与底栏。
struct MainPanel: View {
    @ObservedObject var model: AppModel
    let maxScrollHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(header: model.header, progress: model.checkProgress)
                .padding(.horizontal, PopoverMetrics.padding)
                .padding(.top, 14)
                .padding(.bottom, 10)
            ActionBar(model: model)
                .padding(.horizontal, PopoverMetrics.padding)
                .padding(.bottom, 12)
            Divider()
            BoundedScroll(maxHeight: maxScrollHeight) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(title: "本机状态")
                    ForEach(model.cards) { card in
                        StatusCardView(
                            card: card,
                            expanded: model.expandedCards.contains(card.kind),
                            toggle: { model.toggleEvidence(card.kind) },
                            showRecoveryLink: card.faultKey == .dnsNotRestored,
                            openRecovery: { model.openRecovery() })
                    }
                    EgressIPSection(model: model)
                        .padding(.top, 8)
                    SectionTitle(title: "站点连通性", trailing: "延迟中位数 · 最近 5 次")
                        .padding(.top, 8)
                    if model.settings.enabledSites.isEmpty {
                        Text("未启用公开站点")
                            .font(.system(size: 11.5)).foregroundColor(.secondary)
                    }
                    ForEach(model.siteGroups) { group in
                        SiteGroupView(group: group)
                            .padding(.bottom, 2)
                    }
                    RecentEventsSection(model: model)
                        .padding(.top, 8)
                }
                .padding(.horizontal, PopoverMetrics.padding)
                .padding(.vertical, 12)
            }
            Divider()
            ToolsSection(model: model)
                .padding(.horizontal, PopoverMetrics.padding)
                .padding(.vertical, 10)
            Divider()
            FooterBar(model: model)
        }
    }
}

/// 顶部：徽标、状态名、首要原因、最近检查时间。
struct HeaderView: View {
    let header: HeaderPresentation
    let progress: CheckProgress?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SeverityBadge(severity: header.severity, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(header.statusText)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(header.tone.textColor)
                Text(header.reason)
                    .font(.system(size: 12.5))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let hint = header.hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundColor(header.tone.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let grace = header.graceText {
                    Label(grace, systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.top, 1)
                }
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9.5))
                    Text(header.checkedText)
                    if let progress {
                        Text("·")
                        Text(PopoverFormatter.progressText(progress))
                            .foregroundColor(Color(nsColor: StatusPalette.accent))
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// “立即复测”“复制脱敏诊断摘要”。复测进行中按钮禁用并显示进度。
struct ActionBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.recheck()
                } label: {
                    Label(PopoverFormatter.recheckTitle(model.checkProgress), systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(!model.canRecheck)
                .keyboardShortcut("r", modifiers: .command)

                Button {
                    model.copyDiagnostics()
                } label: {
                    if model.copiedItem == .diagnostics {
                        Label("已复制", systemImage: "checkmark")
                    } else {
                        Label("复制脱敏诊断摘要", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(PillButtonStyle())
                .help("复制不含内网站点 URL、内网 IP 和主目录路径的诊断摘要")
                Spacer(minLength: 0)
            }
            if let progress = model.checkProgress {
                ThinProgressBar(fraction: progress.fraction)
            }
        }
    }
}

/// 手动恢复步骤与两个检测页入口。
/// 最近事件：默认收起；展开后按时间倒序显示最多 10 条。
struct RecentEventsSection: View {
    @ObservedObject var model: AppModel

    static let visibleLimit = 10

    private var events: [FaultEvent] {
        Array(model.recentEvents.suffix(Self.visibleLimit).reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.toggleRecentEvents()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.showsRecentEvents ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 10)
                    SectionTitle(title: "最近事件",
                                 trailing: model.recentEvents.isEmpty ? "暂无" : "\(model.recentEvents.count) 条")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(model.showsRecentEvents ? "已展开" : "已收起")

            if model.showsRecentEvents && !events.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                        if index > 0 { Divider().padding(.leading, 10) }
                        RecentEventRow(event: event,
                                       time: PopoverFormatter.clockText(event.date, now: model.now(),
                                                                        timeZone: model.timeZone))
                    }
                }
                .cardBackground(.neutral)
            }
        }
    }
}

/// 一条事件：状态色点、时间与描述。
struct RecentEventRow: View {
    let event: FaultEvent
    let time: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(Color(nsColor: StatusPalette.mark(StatusTone(event.displaySeverity))))
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(time)
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
            Text(event.text)
                .font(.system(size: 11.5))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(time)，\(event.displaySeverity.displayName)，\(event.text)")
    }
}

struct ToolsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            Button {
                model.openRecovery()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.number")
                        .frame(width: 16)
                        .foregroundColor(model.suggestsRecovery ? StatusTone.critical.textColor : .secondary)
                    Text("查看手动恢复步骤")
                        .fontWeight(model.suggestsRecovery ? .semibold : .regular)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(RowButtonStyle())

            if !model.settings.checkPages.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(model.settings.checkPages.enumerated()), id: \.offset) { _, page in
                        LinkRow(title: page.name, icon: "safari") { model.open(page.url) }
                    }
                }
            }
        }
    }
}

/// 外部检测页入口。
struct LinkRow: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(RowButtonStyle())
        .help("在浏览器中打开")
    }
}

/// 底栏：设置、应用名、退出（应用没有 Dock 图标，这是退出的唯一入口）。
struct FooterBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut(",", modifiers: .command)
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                Image(nsImage: LogoRenderer.appIconImage(pointSize: 15))
                    .resizable()
                    .frame(width: 15, height: 15)
                Text(AppIdentity.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .accessibilityHidden(true)
            Spacer(minLength: 4)
            Button {
                model.quit()
            } label: {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
