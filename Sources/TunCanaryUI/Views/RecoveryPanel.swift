import SwiftUI
import TunCanaryCore

/// 手动恢复步骤（内容来自 `RecoveryGuide`，随应用提供）。
struct RecoveryPanel: View {
    @ObservedObject var model: AppModel
    let maxScrollHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            PanelNavBar(title: RecoveryGuide.title) { model.showMain() }
            Divider()
            BoundedScroll(maxHeight: maxScrollHeight) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("适用于 VPN 断开后、Clash TUN 仍在运行但主网络 DNS 未恢复的情况。应用只读取状态，不会自动修改 DNS 或 TUN。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(model.recoverySteps.enumerated()), id: \.offset) { index, step in
                        RecoveryStepView(
                            number: index + 1,
                            text: step,
                            command: PopoverFormatter.command(in: step),
                            copied: model.copiedItem == .command,
                            copy: { model.copyCommand($0) })
                    }
                }
                .padding(PopoverMetrics.padding)
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    model.recheck()
                    model.showMain()
                } label: {
                    Label(PopoverFormatter.recheckTitle(model.checkProgress), systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(prominent: true, compact: true))
                .disabled(!model.canRecheck)
                Spacer(minLength: 4)
                ForEach(Array(model.settings.checkPages.prefix(2).enumerated()), id: \.offset) { _, page in
                    Button(page.name) { model.open(page.url) }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
            }
            .padding(.horizontal, PopoverMetrics.padding)
            .padding(.vertical, 10)
        }
    }
}

/// 一步：编号 + 说明；含命令时附可复制的命令框。
struct RecoveryStepView: View {
    let number: Int
    let text: String
    let command: String?
    let copied: Bool
    let copy: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color(nsColor: StatusPalette.accent)))
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let command {
                    HStack(spacing: 6) {
                        Text(command)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button {
                            copy(command)
                        } label: {
                            Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(PillButtonStyle(compact: true))
                    }
                    .padding(.leading, 9)
                    .padding(.trailing, 4)
                    .padding(.vertical, 4)
                    .cardBackground(.neutral)
                }
            }
            .padding(.top, 1)
        }
    }
}
