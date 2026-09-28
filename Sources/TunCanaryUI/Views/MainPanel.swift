import SwiftUI
import TunCanaryCore

/// 弹窗主页：总体状态、操作、本机状态、站点结果、出口 IP、最近事件、工具入口与底栏。
struct MainPanel: View {
    @ObservedObject var model: AppModel
    let maxScrollHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(header: model.header, progress: model.checkProgress)
                .padding(.horizontal, PopoverMetrics.padding)
                .padding(.top, 14)
                .padding(.bottom, 8)
            ActionBar(model: model)
                .padding(.horizontal, PopoverMetrics.padding)
                .padding(.bottom, 10)
            Divider()
            BoundedScroll(maxHeight: maxScrollHeight) {
                VStack(alignment: .leading, spacing: PopoverMetrics.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(title: "本机状态")
                            .padding(.horizontal, 2)
                        GroupCard {
                            ForEach(model.cards) { card in
                                StatusRowView(
                                    card: card,
                                    expanded: model.expandedCards.contains(card.kind),
                                    toggle: { model.toggleEvidence(card.kind) },
                                    showRecoveryLink: card.faultKey == .dnsNotRestored,
                                    openRecovery: { model.openRecovery() },
                                    timeZone: model.timeZone)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "站点连通性", trailing: "延迟中位数 · 最近 5 次")
                            .padding(.horizontal, 2)
                        if model.settings.enabledSites.isEmpty {
                            Text("未启用公开站点")
                                .font(Typography.caption).foregroundColor(.secondary)
                                .padding(.horizontal, 2)
                        }
                        ForEach(model.siteGroups) { group in
                            SiteGroupView(group: group, onDiagnose: { model.diagnoseSite($0) })
                        }
                    }
                    EgressIPSection(model: model)
                    GroupCard {
                        RecentEventsRow(model: model)
                    }
                }
                .padding(.horizontal, PopoverMetrics.padding)
                .padding(.vertical, 12)
            }
            Divider()
            ToolsSection(model: model)
                .padding(.horizontal, PopoverMetrics.padding)
                .padding(.vertical, 8)
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
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(header.statusText)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(header.tone.textColor)
                    Spacer(minLength: 4)
                    Label(header.checkedText, systemImage: "clock")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
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
                if let progress {
                    Text(PopoverFormatter.progressText(progress))
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: StatusPalette.accent))
                }
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
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(!model.canRecheck)
                .keyboardShortcut("r", modifiers: .command)

                Button {
                    model.copyDiagnostics()
                } label: {
                    Group {
                        if model.copiedItem == .diagnostics {
                            Label("已复制", systemImage: "checkmark")
                        } else {
                            Label("复制诊断", systemImage: "doc.on.doc")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle())
                .accessibilityLabel(Text("复制脱敏诊断摘要"))
                .help("复制不含 VPN 站点 URL、私有 IP 和主目录路径的诊断摘要")
            }
            if let progress = model.checkProgress {
                ThinProgressBar(fraction: progress.fraction)
            }
        }
    }
}

/// 最近事件：默认收起；展开后按时间倒序显示最多 10 条。
struct RecentEventsRow: View {
    @ObservedObject var model: AppModel

    static let visibleLimit = 10

    private var events: [FaultEvent] {
        Array(model.recentEvents.suffix(Self.visibleLimit).reversed())
    }

    var body: some View {
        DisclosureRow(title: "最近事件",
                      trailing: model.recentEvents.isEmpty ? "暂无" : "\(model.recentEvents.count) 条",
                      isExpanded: model.showsRecentEvents,
                      toggle: { model.toggleRecentEvents() }) {
            if !events.isEmpty {
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

/// 工具入口：手动恢复步骤与检测页排成一行（超过 3 个时排成两行）。需要恢复时“恢复步骤”用红色加粗突出。
struct ToolsSection: View {
    @ObservedObject var model: AppModel

    private enum Item: Hashable {
        case recovery
        case page(Int)
    }

    private var rows: [[Item]] {
        let items = [Item.recovery] + model.settings.checkPages.indices.map(Item.page)
        guard items.count > 3 else { return [items] }
        return stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { item($0) }
                }
            }
        }
    }

    @ViewBuilder private func item(_ item: Item) -> some View {
        switch item {
        case .recovery:
            Button {
                model.openRecovery()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "list.number")
                        .foregroundColor(model.suggestsRecovery ? StatusTone.critical.textColor : .secondary)
                    Text("恢复步骤")
                        .fontWeight(model.suggestsRecovery ? .semibold : .regular)
                        .foregroundColor(model.suggestsRecovery ? StatusTone.critical.textColor : .primary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RowButtonStyle())
            .help("查看手动恢复步骤")
        case .page(let index):
            let page = model.settings.checkPages[index]
            LinkRow(title: page.name, icon: "safari") { model.open(page.url) }
        }
    }
}

/// 外部检测页入口：右上箭头表示在浏览器中打开。
struct LinkRow: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                Text(title)
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(RowButtonStyle())
        .help("在浏览器中打开 \(title)")
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
