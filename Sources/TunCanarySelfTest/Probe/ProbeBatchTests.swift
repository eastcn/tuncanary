import Foundation
import TunCanaryCore
import TunCanaryProbe

/// 线程安全计数器，供并发测试统计“同时进行的请求数”。
private final class ConcurrencyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private(set) var callOrder: [String] = []

    func enter(_ id: String) {
        lock.lock()
        active += 1
        peak = max(peak, active)
        callOrder.append(id)
        lock.unlock()
    }

    func exit() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    var peakCount: Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }
}

/// 线程安全的进度记录，供进度回调测试使用（回调闭包是 `@Sendable`，不能直接捕获可变局部变量）。
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(Int, Int)] = []

    func record(_ done: Int, _ total: Int) {
        lock.lock()
        records.append((done, total))
        lock.unlock()
    }

    var all: [(Int, Int)] {
        lock.lock(); defer { lock.unlock() }
        return records
    }
}

/// 测试专用的假探测器：不访问网络，用 `Task.sleep` 模拟耗时，记录并发情况。
private struct FakeBatchProber: SiteProbing {
    let counter: ConcurrencyCounter
    /// 每站延迟（秒），默认全部相同；可按站点 id 单独指定。
    let delay: @Sendable (String) -> TimeInterval

    func probe(site: Site, attempts: Int, timeout: TimeInterval) async -> SiteResult {
        counter.enter(site.id)
        let seconds = delay(site.id)
        if seconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        counter.exit()
        return SiteAggregator.aggregate(site: site, outcomes: [.http(status: 200, latency: 0.01)], checkedAt: Date())
    }
}

enum ProbeBatchTests {
    static func site(_ id: String) -> Site {
        Site(id: id, name: id, group: .overseas, url: URL(string: "https://stub.test/\(id)")!, isKey: false, inLightProbe: false)
    }

    static var suite: TestSuite {
        TestSuite("Probe.ProbeBatch", [
            TestCase("最大并发不超过 3") { t in
                let counter = ConcurrencyCounter()
                let sites = (0..<9).map { site("s\($0)") }
                let prober = FakeBatchProber(counter: counter, delay: { _ in 0.05 })
                let batch = ProbeBatch(prober: prober, maxConcurrency: 3)
                _ = await batch.run(sites: sites, attempts: 1, timeout: 2)
                t.expect(counter.peakCount <= 3, "观测到的最大并发为 \(counter.peakCount)")
                t.expect(counter.peakCount >= 2, "应当确实发生了并发（观测到 \(counter.peakCount)）")
            },
            TestCase("结果按站点目录顺序返回") { t in
                let counter = ConcurrencyCounter()
                let sites = (0..<6).map { site("s\($0)") }
                // 让较早的站点耗时更长，验证返回顺序仍按输入顺序而不是完成顺序。
                let prober = FakeBatchProber(counter: counter, delay: { id in id == "s0" ? 0.08 : 0.01 })
                let batch = ProbeBatch(prober: prober, maxConcurrency: 3)
                let results = await batch.run(sites: sites, attempts: 1, timeout: 2)
                t.expectEqual(results.map(\.site.id), sites.map(\.id))
            },
            TestCase("进度回调：已完成数 / 总数") { t in
                let counter = ConcurrencyCounter()
                let sites = (0..<5).map { site("s\($0)") }
                let prober = FakeBatchProber(counter: counter, delay: { _ in 0.01 })
                let batch = ProbeBatch(prober: prober, maxConcurrency: 2)
                let log = ProgressLog()
                _ = await batch.run(sites: sites, attempts: 1, timeout: 2) { done, total in
                    log.record(done, total)
                }
                let updates = log.all
                t.expectEqual(updates.count, 5)
                t.expect(updates.allSatisfy { $0.1 == 5 })
                t.expectEqual(updates.map(\.0).sorted(), [1, 2, 3, 4, 5])
            },
            TestCase("空站点列表直接返回空") { t in
                let counter = ConcurrencyCounter()
                let prober = FakeBatchProber(counter: counter, delay: { _ in 0 })
                let batch = ProbeBatch(prober: prober)
                let results = await batch.run(sites: [], attempts: 1, timeout: 2)
                t.expect(results.isEmpty)
            },
        ])
    }
}
