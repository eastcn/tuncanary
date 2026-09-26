import Foundation
import TunCanaryCore
import TunCanaryUI

/// 界面的测试套件。只在 UI/ 目录中添加文件并在此登记。
enum UISuites {
    static var all: [TestSuite] {
        [
            UINotificationMergerTests.suite,
            UIPresentationTests.suite,
            UIAppModelTests.suite,
            UIEgressIPTests.suite,
            UILogoTests.suite,
            UIPlatformTests.suite,
            // 只有设置了 TUNCANARY_RENDER_DIR 时才有用例。
            UIRenderPreviewTests.suite,
        ]
    }
}
