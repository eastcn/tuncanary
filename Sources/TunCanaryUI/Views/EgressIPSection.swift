import SwiftUI
import TunCanaryCore

/// 出口监测：当前采样、变化统计和本机历史。
struct EgressIPSection: View {
    @ObservedObject var model: AppModel
    @State private var historyTarget: EgressSheetTarget?

    private var targets: [EgressIPTarget] { model.settings.effectiveEgressTargets }

    /// 最近一次检测的时间。
    private var checkedText: String? {
        guard let date = model.egressResults.map(\.checkedAt).max() else { return nil }
        return PopoverFormatter.clockText(date, now: model.now(), timeZone: model.timeZone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                SectionTitle(title: "出口 IP")
                Spacer(minLength: 4)
                if let checkedText {
                    Text(checkedText).font(Typography.caption).foregroundColor(.secondary)
                }
                if model.isCheckingEgress {
                    Button("取消") { model.cancelEgressIP() }
                        .buttonStyle(PillButtonStyle(compact: true))
                } else {
                    Button(model.egressResults.isEmpty ? "检测" : "重新检测") { model.checkEgressIP() }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .disabled(model.egressChecker == nil)
                        .help("检测已到期的目标；手动与自动共用间隔及限流冷却")
                }
            }
            .padding(.leading, 2)
            GroupCard {
                ForEach(targets, id: \.self) { target in
                    VStack(alignment: .leading, spacing: 0) {
                        Button { model.toggleEgressDetails(target) } label: {
                            EgressTargetRow(target: target,
                                            result: model.egressResults.first { $0.target == target } ??
                                                (model.isCheckingEgress ? nil : model.egressState.history.last { $0.result.target == target }?.result),
                                            isChecking: model.isCheckingEgress,
                                            isExpanded: model.expandedEgressTargets.contains(target))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(target.displayName) 出口 IP 详情")
                        .accessibilityValue(model.expandedEgressTargets.contains(target) ? "已展开" : "已收起")
                        .help("展开或收起此目标的出口详情")
                        if model.expandedEgressTargets.contains(target) {
                            EgressStabilityRow(model: model, target: target) { historyTarget = EgressSheetTarget(target: target) }
                        }
                    }
                }
            }
            Text("本机历史保留 30 天 · \(model.settings.egressMonitoring.automatic ? "自动检测" : "手动检测") · \(Int(model.settings.egressMonitoring.effectiveInterval / 60)) 分钟间隔")
                .font(Typography.caption).foregroundColor(.secondary)
            if let error = model.egressPersistenceError { ErrorText(text: error) }
        }
        .sheet(item: $historyTarget) { selected in EgressHistoryView(model: model, target: selected.target) }
    }
}

/// 一个出口检测目标：名称与 IP 同一行，版本与归属地在名称下方。
struct EgressTargetRow: View {
    let target: EgressIPTarget
    let result: EgressIPResult?
    let isChecking: Bool
    let isExpanded: Bool

    /// 自定义目标常见的失败原因：站点不经 Cloudflare，没有 trace 地址。
    private var failureText: String? {
        guard let result, result.ip == nil else { return nil }
        let text = result.failure?.displayName ?? "未取得结果"
        guard !target.isBuiltIn && target.endpoint == nil else { return text }
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
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, PopoverMetrics.rowHorizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}


struct EgressStabilityRow: View {
    @ObservedObject var model: AppModel
    let target: EgressIPTarget
    let showHistory: () -> Void
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { _ in
            let summary = model.egressSummary(target)
            let control = model.egressState.controls[target.rawValue]
            VStack(alignment: .leading, spacing: 3) {
                Text(target.host).lineLimit(1)
                if let latest = summary.latest {
                    if let geo = latest.geo {
                        Text(geo.displayName + (geo.isFresh(at: model.now()) ? "" : "（过期）"))
                        if let loc = latest.result.location, String(loc.prefix(2)) != geo.countryCode {
                            Text("目标地域：\(loc)；地域库：\(geo.countryCode)，来源不一致")
                                .foregroundColor(StatusTone.warning.textColor)
                        }
                    } else { Text("地域未知") }
                    Text("上次：\(latest.result.checkedAt.formatted(date: .abbreviated, time: .standard))")
                    Text("30 天内 \(summary.samples) 次采样 · \(summary.changes) 次 IP 变化 · \(summary.failures) 次失败")
                    if let since = summary.observedSince, summary.samples > 1 {
                        Text("采样未见变化：自 \(since.formatted(date: .abbreviated, time: .standard)) 起；不含采样间隙")
                    } else { Text("稳定性待确认或采样已中断") }
                    if model.egressState.regionAlerts[target.rawValue]?.active == true {
                        Text(latest.regionIsFresh && summary.observedSince != nil ? "地域超出允许范围（已连续确认）" : "上次已确认地域越界，当前状态待确认").foregroundColor(StatusTone.warning.textColor)
                    }
                }
                HStack {
                    if control?.suspended == true {
                        Text("自动检测已暂停").foregroundColor(StatusTone.warning.textColor)
                        Button("恢复") { model.resumeEgressTarget(target) }.buttonStyle(.plain)
                    } else if let next = control?.nextAttempt, next > model.now() {
                        Text("下次允许检测：\(next.formatted(date: .omitted, time: .standard))")
                    }
                    Spacer()
                    Button("历史", action: showHistory).buttonStyle(.plain)
                }
            }
            .font(Typography.caption).foregroundColor(.secondary)
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }
}

struct EgressHistoryView: View {
    @ObservedObject var model: AppModel
    let target: EgressIPTarget
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(target.displayName)：出口历史").font(.headline)
            Text("\(target.host) · 本机保留 30 天 · IPv4 / IPv6 分开比较")
                .font(.caption).foregroundColor(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.egressState.history.filter { $0.result.target == target }.reversed().enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.result.checkedAt.formatted(date: .abbreviated, time: .standard))
                            if let ip = item.result.ip {
                                Text("\(item.result.ipVersion?.displayName ?? "")  \(ip)").monospaced().textSelection(.enabled)
                                Text(item.geo.map { "\($0.displayName) · \($0.source)\(item.regionIsFresh ? "" : "（地域未确认）")" } ?? "地域未知")
                            } else { Text(item.result.failure?.displayName ?? "未确认").foregroundColor(.orange) }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("两次采样之间的短暂变化可能未被观察到。历史包含完整出口 IP，仅保存在本机。")
                .font(.caption).foregroundColor(.secondary)
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 540, height: 500)
    }
}
