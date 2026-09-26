import Foundation
@preconcurrency import TunCanaryCore

/// 线程安全的完成计数器，供进度回调使用。
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// 手动“立即复测”/完整检测用：对一组站点执行探测，限制最大并发站点数，结果按输入顺序返回。
///
/// 并发语义：内部用 `withTaskGroup` 并发调度，同一时间最多 `maxConcurrency` 个站点在探测；
/// 每个站点内部仍是串行的 `attempts` 次请求（见 `SiteProbing.probe`）。`progress` 回调在每个
/// 站点完成时触发一次，可能在任意 Task 的执行上下文中被调用（非固定线程/Actor），调用方如需
/// 更新 UI，应自行跳回主线程。取消：若外层 `Task` 被取消，`run` 不再调度新的站点，已在途的
/// 请求仍会按各自的超时/看门狗自然结束，最终只返回已完成的部分结果。
public struct ProbeBatch: Sendable {
    private let prober: SiteProbing
    private let maxConcurrency: Int

    public init(prober: SiteProbing, maxConcurrency: Int = PulseConstants.fullProbeConcurrency) {
        self.prober = prober
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// 探测 `sites`，每站 `attempts` 次请求，单次超时 `timeout`。
    /// 返回值与 `sites` 顺序一致；被取消时可能少于 `sites.count`。
    public func run(
        sites: [Site],
        attempts: Int,
        timeout: TimeInterval,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> [SiteResult] {
        guard !sites.isEmpty, !Task.isCancelled else { return [] }
        let total = sites.count
        let counter = ProgressCounter()
        var results = [SiteResult?](repeating: nil, count: total)

        await withTaskGroup(of: (Int, SiteResult).self) { group in
            var nextIndex = 0
            var active = 0

            func startNext() {
                guard nextIndex < total else { return }
                let index = nextIndex
                nextIndex += 1
                active += 1
                let site = sites[index]
                let prober = self.prober
                group.addTask {
                    let result = await prober.probe(site: site, attempts: attempts, timeout: timeout)
                    return (index, result)
                }
            }

            let initial = min(maxConcurrency, total)
            for _ in 0..<initial { startNext() }

            while active > 0 {
                guard let (index, result) = await group.next() else { break }
                results[index] = result
                active -= 1
                let done = counter.increment()
                progress?(done, total)

                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                startNext()
            }
        }

        return results.compactMap { $0 }
    }
}
