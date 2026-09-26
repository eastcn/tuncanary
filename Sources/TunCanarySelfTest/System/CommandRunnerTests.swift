import Foundation
import TunCanaryCore
import TunCanarySystem

/// 带超时的命令执行测试。
enum CommandRunnerTests {
    static var suite: TestSuite {
        TestSuite("System.CommandRunner", [
            TestCase("读取标准输出与退出码") { t in
                let result = CommandRunner().run("/bin/echo", ["hello", "世界"], timeout: 3)
                t.expectEqual(result.termination, .exited(0))
                t.expect(result.succeeded)
                t.expectEqual(result.outputText, "hello 世界\n")
                t.expectEqual(result.errorText, "")
                t.expect(!result.outputTruncated)
                t.expectNil(result.failureReason(name: "echo", timeout: 3))
            },
            TestCase("非零退出码与标准错误") { t in
                let result = CommandRunner().run("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"], timeout: 3)
                t.expectEqual(result.termination, .exited(3))
                t.expectEqual(result.outputText, "out\n")
                t.expectEqual(result.errorText, "err\n")
                t.expectEqual(result.failureReason(name: "sh", timeout: 3), "sh 退出码 3")
            },
            TestCase("超时后终止子进程", timeout: 10) { t in
                let start = Date()
                let result = CommandRunner().run("/bin/sleep", ["5"], timeout: 1)
                let elapsed = Date().timeIntervalSince(start)
                t.expectEqual(result.termination, .timedOut)
                t.expect(elapsed >= 0.9 && elapsed < 2.5, "耗时 \(elapsed)")
                t.expectEqual(result.failureReason(name: "sleep", timeout: 1), "sleep 超时（1 秒）")
            },
            TestCase("超时后连同孙进程一起终止", timeout: 10) { t in
                // 孙进程继承了管道：只杀子进程的话，读取会一直等到孙进程结束。
                let start = Date()
                let result = CommandRunner().run("/bin/sh", ["-c", "/bin/sleep 5 & /bin/sleep 5; wait"], timeout: 1)
                let elapsed = Date().timeIntervalSince(start)
                t.expectEqual(result.termination, .timedOut)
                t.expect(elapsed < 2.5, "耗时 \(elapsed)")
            },
            TestCase("子进程已退出但孙进程占着管道也按超时处理", timeout: 10) { t in
                let start = Date()
                let result = CommandRunner().run("/bin/sh", ["-c", "echo started; /bin/sleep 5 &"], timeout: 1)
                let elapsed = Date().timeIntervalSince(start)
                t.expectEqual(result.termination, .timedOut)
                t.expectEqual(result.outputText, "started\n")
                t.expect(elapsed < 2.5, "耗时 \(elapsed)")
            },
            TestCase("大量输出不死锁（stdout 与 stderr 同时写满）", timeout: 15) { t in
                let script = "head -c 1048576 /dev/zero 1>&2; head -c 4194304 /dev/zero; head -c 1048576 /dev/zero 1>&2"
                let result = CommandRunner().run("/bin/sh", ["-c", script], timeout: 10)
                t.expectEqual(result.termination, .exited(0))
                t.expectEqual(result.standardOutput.count, 4 << 20)
                t.expectEqual(result.standardError.count, 2 << 20)
                t.expect(!result.outputTruncated)
            },
            TestCase("超过上限的输出被截断但仍读完", timeout: 15) { t in
                let runner = CommandRunner(maxOutputBytes: 1000)
                let result = runner.run("/bin/sh", ["-c", "head -c 2097152 /dev/zero"], timeout: 10)
                t.expectEqual(result.termination, .exited(0))
                t.expectEqual(result.standardOutput.count, 1000)
                t.expect(result.outputTruncated)
            },
            TestCase("无法启动") { t in
                let result = CommandRunner().run("/nonexistent/tuncanary-command", [], timeout: 1)
                guard case .launchFailed(let reason) = result.termination else {
                    t.fail("应为 launchFailed：\(result.termination)")
                    return
                }
                t.expectContains(reason, "errno 2")
                t.expectContains(result.failureReason(name: "x", timeout: 1) ?? "", "无法启动 x")
            },
            TestCase("被信号终止") { t in
                let result = CommandRunner().run("/bin/sh", ["-c", "kill -9 $$"], timeout: 3)
                t.expectEqual(result.termination, .signaled(9))
            },
            TestCase("固定使用 C 语言环境") { t in
                let result = CommandRunner().run("/usr/bin/env", [], timeout: 3)
                t.expectContains(result.outputText, "LC_ALL=C")
                t.expectNotContains(result.outputText, "HOME=")
            },
            TestCase("异步执行") { t in
                let result = await CommandRunner().runAsync("/bin/echo", ["async"], timeout: 3)
                t.expectEqual(result.outputText, "async\n")
            },
            TestCase("并发执行互不干扰", timeout: 15) { t in
                let runner = CommandRunner()
                let results = await withTaskGroup(of: (Int, CommandResult).self) { group in
                    for index in 0..<8 {
                        group.addTask { (index, await runner.runAsync("/bin/echo", ["\(index)"], timeout: 3)) }
                    }
                    var collected: [Int: CommandResult] = [:]
                    for await (index, result) in group { collected[index] = result }
                    return collected
                }
                for index in 0..<8 {
                    t.expectEqual(results[index]?.outputText, "\(index)\n")
                }
            },
            TestCase("wait 状态解析") { t in
                t.expectEqual(CommandRunner.decode(0), .exited(0))
                t.expectEqual(CommandRunner.decode(3 << 8), .exited(3))
                t.expectEqual(CommandRunner.decode(9), .signaled(9))
            },
        ])
    }
}
