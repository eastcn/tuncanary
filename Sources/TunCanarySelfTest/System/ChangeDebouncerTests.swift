import Foundation
import TunCanaryCore
import TunCanarySystem

/// 去抖纯逻辑测试（时间全部注入）。
enum ChangeDebouncerTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_424_000)

    static func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    static var suite: TestSuite {
        TestSuite("System.ChangeDebouncer", [
            TestCase("单次变化 2 秒后输出") { t in
                var debouncer = ChangeDebouncer()
                t.expectNil(debouncer.record(.network, at: at(0)))
                t.expectEqual(debouncer.deadline, at(2))
                t.expectNil(debouncer.fire(at: at(1.9)))
                t.expectEqual(debouncer.fire(at: at(2)), NetworkChangeEvent(reason: .network, date: at(0)))
                t.expectNil(debouncer.deadline)
                t.expectNil(debouncer.fire(at: at(10)), "已输出后不再重复")
            },
            TestCase("一串变化合并，时间取第一次") { t in
                var debouncer = ChangeDebouncer()
                debouncer.record(.network, at: at(0))
                debouncer.record(.network, at: at(1))
                debouncer.record(.network, at: at(2.5))
                t.expectEqual(debouncer.burst?.count, 3)
                t.expectEqual(debouncer.deadline, at(4.5))
                t.expectNil(debouncer.fire(at: at(4.4)))
                t.expectEqual(debouncer.fire(at: at(4.5)), NetworkChangeEvent(reason: .network, date: at(0)))
            },
            TestCase("持续抖动时最迟 maxDelay 输出") { t in
                var debouncer = ChangeDebouncer(quietInterval: 2, maxDelay: 6)
                var emitted: [NetworkChangeEvent] = []
                // 每 1 秒一次变化，持续 10 秒；每 0.5 秒检查一次。
                var time: TimeInterval = 0
                while time <= 10 {
                    if time.truncatingRemainder(dividingBy: 1) == 0 { debouncer.record(.network, at: at(time)) }
                    if let event = debouncer.fire(at: at(time)) { emitted.append(event) }
                    time += 0.5
                }
                t.expectEqual(emitted, [NetworkChangeEvent(reason: .network, date: at(0))])
                // 第二串从 7 秒开始，停止变化后 2 秒输出。
                t.expectEqual(debouncer.burst?.firstDate, at(7))
                t.expectEqual(debouncer.fire(at: at(12)), NetworkChangeEvent(reason: .network, date: at(7)))
            },
            TestCase("唤醒与网络变化合并为唤醒") { t in
                var debouncer = ChangeDebouncer()
                debouncer.record(.network, at: at(0))
                debouncer.record(.wake, at: at(0.5))
                debouncer.record(.network, at: at(1))
                t.expectEqual(debouncer.fire(at: at(3)), NetworkChangeEvent(reason: .wake, date: at(0)))
            },
            TestCase("睡眠立即输出并丢弃未输出的变化") { t in
                var debouncer = ChangeDebouncer()
                debouncer.record(.network, at: at(0))
                t.expectEqual(debouncer.record(.sleep, at: at(1)), NetworkChangeEvent(reason: .sleep, date: at(1)))
                t.expectNil(debouncer.deadline)
                t.expectEqual(debouncer.sleepingSince, at(1))
            },
            TestCase("入睡过程中的网络变化被忽略，唤醒后重新计时") { t in
                var debouncer = ChangeDebouncer()
                debouncer.record(.sleep, at: at(0))
                t.expectNil(debouncer.record(.network, at: at(1)))
                t.expectNil(debouncer.deadline, "睡眠后 30 秒内的网络变化忽略")
                // 唤醒（墙钟已过去很久）
                debouncer.record(.wake, at: at(3600))
                debouncer.record(.network, at: at(3601))
                t.expectNil(debouncer.sleepingSince)
                t.expectEqual(debouncer.deadline, at(3603))
                t.expectEqual(debouncer.fire(at: at(3603)), NetworkChangeEvent(reason: .wake, date: at(3600)))
            },
            TestCase("收不到唤醒通知时，抑制期过后恢复处理") { t in
                var debouncer = ChangeDebouncer(sleepSuppression: 30)
                debouncer.record(.sleep, at: at(0))
                t.expectNil(debouncer.record(.network, at: at(29)))
                t.expectNil(debouncer.deadline)
                debouncer.record(.network, at: at(31))
                t.expectNil(debouncer.sleepingSince)
                t.expectEqual(debouncer.fire(at: at(33)), NetworkChangeEvent(reason: .network, date: at(31)))
            },
            TestCase("乱序时间取最早") { t in
                var debouncer = ChangeDebouncer()
                debouncer.record(.network, at: at(1))
                debouncer.record(.network, at: at(0.5))
                t.expectEqual(debouncer.burst?.firstDate, at(0.5))
                t.expectEqual(debouncer.deadline, at(3))
            },
            TestCase("reset 清空") { t in
                var debouncer = ChangeDebouncer()
                debouncer.record(.sleep, at: at(0))
                debouncer.record(.wake, at: at(5))
                debouncer.reset()
                t.expectNil(debouncer.burst)
                t.expectNil(debouncer.sleepingSince)
                t.expectNil(debouncer.fire(at: at(100)))
            },
            TestCase("参数下限") { t in
                let debouncer = ChangeDebouncer(quietInterval: 2, maxDelay: 1, sleepSuppression: -1)
                t.expectEqual(debouncer.maxDelay, 2, "maxDelay 不小于去抖间隔")
                t.expectEqual(debouncer.sleepSuppression, 0)
                t.expectEqual(ChangeDebouncer().quietInterval, PulseConstants.eventDebounce)
            },
        ])
    }
}
