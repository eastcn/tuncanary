import Foundation
import TunCanaryCore
import TunCanarySystem

/// 系统采集的测试套件。只在 System/ 目录中添加文件并在此登记。
enum SystemSuites {
    static var all: [TestSuite] {
        [
            DNSMessageTests.suite,
            DNSMessageTests.clientSuite,
            ChangeDebouncerTests.suite,
            CommandRunnerTests.suite,
            CollectorTests.processSuite,
            CollectorTests.interfaceSuite,
            CollectorTests.dynamicStoreSuite,
            CollectorTests.fileSuite,
            SnapshotProviderTests.suite,
            ObserverTests.suite,
        ] + (ProcessInfo.processInfo.environment["TUNCANARY_LIVE"] == "1" ? [LiveSmokeTests.suite] : [])
    }
}
