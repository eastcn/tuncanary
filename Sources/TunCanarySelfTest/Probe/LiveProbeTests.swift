import Foundation
import TunCanaryCore
import TunCanaryProbe

/// 实机连通性检查：对 `SiteCatalog` 中的 9 个公网站点各探测 1 次，打印类别、状态码和延迟。
/// 不做断言，只是把真实结果打印出来供人工核对；默认跳过，设置环境变量 `TUNCANARY_LIVE=1` 才运行。
/// 本机的请求会经过 Clash TUN，属于预期行为。
enum LiveProbeTests {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TUNCANARY_LIVE"] == "1"
    }

    static var suite: TestSuite {
        TestSuite("Probe.Live", [
            TestCase("9 个公网站点各探测一次", timeout: 90) { t in
                guard isEnabled else {
                    print("  跳过：设置环境变量 TUNCANARY_LIVE=1 后才会执行实机探测")
                    return
                }
                let prober = URLSessionSiteProber()
                print("  站点\t\t类别\t\t状态码\t延迟")
                for site in FixtureLoader.legacySites {
                    let result = await prober.probe(site: site, attempts: 1, timeout: PulseConstants.probeTimeout)
                    let status = result.attempts.first?.httpStatus.map(String.init) ?? "-"
                    let latency = result.medianLatency.map(LatencyFormat.milliseconds) ?? "-"
                    print("  \(site.name)\t\(result.category.displayName)\t\(status)\t\(latency)")
                }
                t.expect(true) // 仅打印，不断言
            },
        ])
    }
}
