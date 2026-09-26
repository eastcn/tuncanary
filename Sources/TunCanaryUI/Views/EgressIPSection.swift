import SwiftUI
import TunCanaryCore

struct EgressIPSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("本应用出口 IP").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if model.isCheckingEgress {
                    Text("检测中…").font(.system(size: 11)).foregroundColor(.secondary)
                    Button("取消") { model.cancelEgressIP() }
                        .buttonStyle(PillButtonStyle(compact: true))
                } else {
                    Button(model.egressResults.isEmpty ? "检测出口" : "重新检测") { model.checkEgressIP() }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .disabled(model.egressChecker == nil)
                }
            }
            Text("点击后访问 \(model.settings.effectiveEgressTargets.map(\.displayName).joined(separator: " 和 "))；结果仅代表本应用到对应目标的出口。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.egressResults, id: \.target) { result in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(result.target.displayName).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(result.checkedAt, style: .time)
                            .font(.system(size: 10.5)).foregroundColor(.secondary)
                    }
                    if let ip = result.ip {
                        Text(ip).font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text([result.ipVersion?.displayName, result.location].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    } else {
                        Text(result.failure?.displayName ?? "未取得结果")
                            .font(.system(size: 11.5)).foregroundColor(StatusTone.warning.textColor)
                    }
                }
                .padding(8)
                .cardBackground(.neutral)
            }
        }
    }
}
