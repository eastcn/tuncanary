import Foundation

/// TunCanaryCore 的全部测试套件。
enum CoreSuites {
    static var all: [TestSuite] {
        [
            BasicsTests.suite,
            EgressMonitoringTests.suite,
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
            DNSGuardTests.suite,
            DNSGuardDaemonTests.suite,
            ProxyClientTests.suite,
            FakeIPFilterTests.suite,
            ConnectivityTests.suite,
            SummaryTests.suite,
            NotificationTests.suite,
            FaultEventTests.suite,
            GraceTests.suite,
            CLITests.suite,
            SettingsTests.suite,
            DiagnosticsTests.suite,
            TailnetTests.suite,
            ProxyDiagnosisTests.suite,
        ]
    }
}
