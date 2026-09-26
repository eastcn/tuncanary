import Foundation

/// TunCanaryCore 的全部测试套件。
enum CoreSuites {
    static var all: [TestSuite] {
        [
            BasicsTests.suite,
            IPv4Tests.suite,
            ClashConfigParserTests.suite,
            VPNStatusFileParserTests.suite,
            ScutilDNSParserTests.suite,
            NetstatRouteParserTests.suite,
            IfconfigParserTests.suite,
            ScutilDictionaryParserTests.suite,
            FixtureTests.suite,
            LocalEvaluatorTests.suite,
            VPNTests.suite,
            DNSRuleTests.suite,
            ProxyClientTests.suite,
            FakeIPFilterTests.suite,
            ConnectivityTests.suite,
            SummaryTests.suite,
            NotificationTests.suite,
            GraceTests.suite,
            CLITests.suite,
            SettingsTests.suite,
            DiagnosticsTests.suite,
        ]
    }
}
