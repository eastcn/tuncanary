import Foundation

// 轻量测试工具：没有 XCTest / Testing，自带断言、过滤、汇总与超时。
// 各模块的用例放在 Core/System/Probe/UI/Runtime 目录中，并在对应的 *Suites.swift 登记。

/// 一个测试用例。闭包可以是同步或 async。
struct TestCase {
    let name: String
    let timeout: TimeInterval
    let body: (TestContext) async throws -> Void

    /// - Parameter timeout: 单个用例的超时（秒），默认 20 秒。
    init(_ name: String, timeout: TimeInterval = 20, _ body: @escaping (TestContext) async throws -> Void) {
        self.name = name
        self.timeout = timeout
        self.body = body
    }
}

/// 一组测试用例。
struct TestSuite {
    let name: String
    let cases: [TestCase]

    init(_ name: String, _ cases: [TestCase]) {
        self.name = name
        self.cases = cases
    }
}

/// 断言失败记录。
struct TestFailure: CustomStringConvertible {
    let message: String
    /// 源文件路径；运行器自身产生的失败（超时、未处理的错误）为 nil。
    let file: String?
    let line: UInt

    var description: String {
        guard let file else { return message }
        let root = TestPaths.repoRoot.path + "/"
        let shown = file.hasPrefix(root) ? String(file.dropFirst(root.count)) : file
        return "\(shown):\(line): \(message)"
    }
}

/// `require` 失败时抛出，用于提前结束当前用例。
struct RequirementFailed: Error {}

/// 用例上下文：收集断言失败。
final class TestContext: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TestFailure] = []

    var failures: [TestFailure] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ message: String, file: StaticString, line: UInt) {
        append(TestFailure(message: message, file: "\(file)", line: line))
    }

    func append(_ failure: TestFailure) {
        lock.lock()
        storage.append(failure)
        lock.unlock()
    }

    /// 断言条件为真。
    func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            if try !condition() {
                let extra = message()
                record("期望为真" + (extra.isEmpty ? "" : "：\(extra)"), file: file, line: line)
            }
        } catch {
            record("表达式抛出错误：\(error)", file: file, line: line)
        }
    }

    /// 断言相等，失败时打印实际值与期望值。
    func expectEqual<T: Equatable>(
        _ actual: @autoclosure () throws -> T,
        _ expected: @autoclosure () throws -> T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let a = try actual()
            let e = try expected()
            if a != e {
                let extra = message()
                record("不相等" + (extra.isEmpty ? "" : "（\(extra)）")
                    + "\n      实际：\(String(reflecting: a))\n      期望：\(String(reflecting: e))",
                    file: file, line: line)
            }
        } catch {
            record("表达式抛出错误：\(error)", file: file, line: line)
        }
    }

    /// 断言文本包含子串。
    func expectContains(
        _ text: String,
        _ substring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !text.contains(substring) {
            record("未包含子串\n      文本：\(String(reflecting: text))\n      子串：\(String(reflecting: substring))",
                   file: file, line: line)
        }
    }

    /// 断言文本不包含子串。
    func expectNotContains(
        _ text: String,
        _ substring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if text.contains(substring) {
            record("不应包含子串\n      文本：\(String(reflecting: text))\n      子串：\(String(reflecting: substring))",
                   file: file, line: line)
        }
    }

    /// 断言为 nil。
    func expectNil<T>(
        _ value: @autoclosure () throws -> T?,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            if let v = try value() {
                let extra = message()
                record("期望为 nil" + (extra.isEmpty ? "" : "（\(extra)）") + "\n      实际：\(String(reflecting: v))",
                       file: file, line: line)
            }
        } catch {
            record("表达式抛出错误：\(error)", file: file, line: line)
        }
    }

    /// 断言会抛错。
    func expectThrows<T>(
        _ expression: @autoclosure () throws -> T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let value = try expression()
            let extra = message()
            record("期望抛出错误" + (extra.isEmpty ? "" : "（\(extra)）") + "\n      实际返回：\(String(reflecting: value))",
                   file: file, line: line)
        } catch {}
    }

    /// 取出非 nil 值，否则记录失败并结束当前用例。
    func require<T>(
        _ value: @autoclosure () throws -> T?,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        let result: T?
        do {
            result = try value()
        } catch {
            record("表达式抛出错误：\(error)", file: file, line: line)
            throw RequirementFailed()
        }
        guard let unwrapped = result else {
            let extra = message()
            record("require 失败：值为 nil" + (extra.isEmpty ? "" : "（\(extra)）"), file: file, line: line)
            throw RequirementFailed()
        }
        return unwrapped
    }

    /// 直接记录失败。
    func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        record(message, file: file, line: line)
    }
}

/// 测试运行器：过滤、执行、汇总。
enum TestRunner {
    struct Options {
        var filters: [String] = []
        var list = false
        var help = false
    }

    static let usage = """
    用法：scripts/test.sh [--list] [过滤词 ...]
      过滤词匹配 “套件名/用例名”（不区分大小写的子串），多个过滤词取并集。
      例：scripts/test.sh ClashConfigParser
          scripts/test.sh "LocalEvaluator/Tailscale"
      --list  只列出匹配的用例
    """

    static func parseArguments(_ arguments: [String]) -> Options {
        var options = Options()
        for argument in arguments {
            switch argument {
            case "--list", "-l": options.list = true
            case "--help", "-h": options.help = true
            default: options.filters.append(argument)
            }
        }
        return options
    }

    static func matches(suite: String, testCase: String, filters: [String]) -> Bool {
        guard !filters.isEmpty else { return true }
        let full = "\(suite)/\(testCase)"
        return filters.contains { full.range(of: $0, options: [.caseInsensitive]) != nil }
    }

    /// 运行并返回退出码（0 全部通过，1 有失败或没有匹配的用例）。
    static func run(suites: [TestSuite], arguments: [String]) async -> Int32 {
        let options = parseArguments(arguments)
        if options.help {
            print(usage)
            return 0
        }

        let selected: [(TestSuite, [TestCase])] = suites.compactMap { suite in
            let cases = suite.cases.filter { matches(suite: suite.name, testCase: $0.name, filters: options.filters) }
            return cases.isEmpty ? nil : (suite, cases)
        }
        let total = selected.reduce(0) { $0 + $1.1.count }

        if options.list {
            for (suite, cases) in selected {
                for testCase in cases { print("\(suite.name)/\(testCase.name)") }
            }
            print("共 \(total) 个用例")
            return 0
        }

        guard total > 0 else {
            print("没有匹配的用例：\(options.filters.joined(separator: " "))")
            return 1
        }

        let started = Date()
        var failedNames: [String] = []
        for (suite, cases) in selected {
            print("▶ \(suite.name)")
            for testCase in cases {
                let caseStart = Date()
                let failures = await execute(testCase)
                let elapsed = Int(Date().timeIntervalSince(caseStart) * 1000)
                if failures.isEmpty {
                    print("  ✓ \(testCase.name) (\(elapsed) ms)")
                } else {
                    failedNames.append("\(suite.name)/\(testCase.name)")
                    print("  ✕ \(testCase.name) (\(elapsed) ms)")
                    for failure in failures { print("    - \(failure)") }
                }
                fflush(stdout)
            }
        }

        let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
        print("")
        print("汇总：\(total) 个用例，通过 \(total - failedNames.count)，失败 \(failedNames.count)（\(seconds) 秒）")
        if !failedNames.isEmpty {
            print("失败的用例：")
            for name in failedNames { print("  - \(name)") }
        }
        return failedNames.isEmpty ? 0 : 1
    }

    /// 执行单个用例，带超时。超时后不再等待该用例。
    static func execute(_ testCase: TestCase) async -> [TestFailure] {
        let context = TestContext()
        let gate = ResumeGate()
        let body = testCase.body
        let timeout = testCase.timeout

        let timedOut: Bool = await withCheckedContinuation { continuation in
            let task = Task {
                do {
                    try await body(context)
                } catch is RequirementFailed {
                    // 已记录
                } catch {
                    context.append(TestFailure(message: "抛出未处理的错误：\(error)", file: nil, line: 0))
                }
                if gate.claim() { continuation.resume(returning: false) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if gate.claim() {
                    task.cancel()
                    continuation.resume(returning: true)
                }
            }
        }
        var failures = context.failures
        if timedOut {
            let seconds = timeout == timeout.rounded() ? String(Int(timeout)) : String(format: "%.1f", timeout)
            failures.append(TestFailure(message: "超时（\(seconds) 秒）", file: nil, line: 0))
        }
        return failures
    }
}

/// 只允许一次 resume 的门闩。
final class ResumeGate: @unchecked Sendable {
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
