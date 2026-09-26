import SwiftUI
import TunCanaryCore

/// 弹窗根视图：按 `AppModel.route` 显示主页、设置或手动恢复步骤。宽度固定为 380 pt。
public struct PopoverRootView: View {
    @ObservedObject private var model: AppModel
    private let maxScrollHeight: CGFloat?

    /// - Parameter maxScrollHeight: 中部可滚动区域的最大高度；nil 表示全部展开（离屏渲染用）。
    public init(model: AppModel, maxScrollHeight: CGFloat? = PopoverMetrics.defaultMaxScrollHeight) {
        self.model = model
        self.maxScrollHeight = maxScrollHeight
    }

    public var body: some View {
        Group {
            switch model.route {
            case .main:
                MainPanel(model: model, maxScrollHeight: maxScrollHeight)
            case .settings:
                SettingsPanel(model: model, maxScrollHeight: maxScrollHeight)
            case .recovery:
                RecoveryPanel(model: model, maxScrollHeight: maxScrollHeight)
            }
        }
        .frame(width: PopoverMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}
