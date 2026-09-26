import Darwin
import Foundation
import TunCanaryCore
import os

/// 系统采集中的错误，`message` 为中文原因，直接写进 `Collected.failed(reason:)`。
public struct SystemCollectionError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// 单调时钟（秒），用于测量耗时与计算超时，不受系统时间调整影响。
enum Monotonic {
    static func now() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// 在 GCD 全局队列上执行阻塞调用，避免占用 Swift 并发的协作线程池。
enum Blocking {
    static func run<T: Sendable>(
        qos: DispatchQoS.QoSClass = .utility,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: body())
            }
        }
    }

    /// 执行并测量耗时（秒）。
    static func timed<T: Sendable>(
        qos: DispatchQoS.QoSClass = .utility,
        _ body: @escaping @Sendable () -> T
    ) async -> (T, TimeInterval) {
        await run(qos: qos) {
            let start = Monotonic.now()
            let value = body()
            return (value, Monotonic.now() - start)
        }
    }
}

/// 只允许成功一次的标记，用于超时竞速时保证 continuation 只 resume 一次。
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

extension NSLock {
    /// 加锁执行（不依赖 macOS 14 的 `withLock`）。
    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// errno 的中文描述片段，例如 “errno 13：Permission denied”。
func errnoDescription(_ code: Int32 = errno) -> String {
    "errno \(code)：\(String(cString: strerror(code)))"
}

/// 模块日志。动态值默认为 private，不写日志文件。
enum SystemLog {
    /// Logger 本身线程安全，但 macOS 14.4 SDK 未标注 Sendable。
    nonisolated(unsafe) static let logger = Logger(subsystem: AppIdentity.bundleID, category: "system")
}
