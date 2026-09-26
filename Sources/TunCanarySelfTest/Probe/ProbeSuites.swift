import Foundation
import TunCanaryCore
import TunCanaryProbe

/// 网络探测的测试套件。只在 Probe/ 目录中添加文件并在此登记。
enum ProbeSuites {
    static var all: [TestSuite] {
        [
            URLSessionSiteProberTests.suite,
            EgressIPTests.suite,
            ProbeBatchTests.suite,
            CheckRunnerTests.suite,
        ] + (ProcessInfo.processInfo.environment["TUNCANARY_LIVE"] == "1" ? [LiveProbeTests.suite] : [])
    }
}
