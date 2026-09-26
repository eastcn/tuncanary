import Foundation
import TunCanaryCore
import TunCanarySystem

/// 网络变化监听测试。去抖间隔缩短为 0.2 秒；系统事件源只验证安装与拆除，变化通过 `noteRawChange` 注入。
enum ObserverTests {
    typealias Events = SystemTestKit.Box<[NetworkChangeEvent]>

    static func makeObserver(debounce: TimeInterval = 0.2,
                             sources: SystemNetworkChangeObserver.Sources = [],
                             now: @escaping @Sendable () -> Date = { Date() }) -> SystemNetworkChangeObserver {
        SystemNetworkChangeObserver(debounce: debounce, maxDelay: debounce * 5, sources: sources, now: now)
    }

    static func collecting(_ observer: SystemNetworkChangeObserver) -> Events {
        let events = Events([])
        observer.start { event in events.mutate { $0.append(event) } }
        return events
    }

    static var suite: TestSuite {
        TestSuite("System.NetworkChangeObserver", [
            TestCase("一串变化去抖后回调一次，时间取第一次", timeout: 5) { t in
                let observer = makeObserver(debounce: 0.4)
                let events = collecting(observer)
                defer { observer.stop() }
                let first = Date()
                observer.noteRawChange(.network)
                await SystemTestKit.sleep(0.05)
                observer.noteRawChange(.network)
                await SystemTestKit.sleep(0.05)
                observer.noteRawChange(.network)
                await SystemTestKit.sleep(0.15)
                t.expectEqual(events.value.count, 0, "去抖期间不回调")
                await SystemTestKit.sleep(0.6)
                let received = events.value
                t.expectEqual(received.count, 1)
                t.expectEqual(received.first?.reason, .network)
                if let date = received.first?.date {
                    t.expect(date >= first && date.timeIntervalSince(first) < 0.05, "事件时间应为第一次变化")
                }
            },
            TestCase("注入的时钟决定事件时间", timeout: 5) { t in
                let start = Date(timeIntervalSince1970: 1_790_424_000)
                let clock = SystemTestKit.Box(start)
                let observer = makeObserver(now: { clock.value })
                let events = collecting(observer)
                defer { observer.stop() }
                observer.noteRawChange(.wake)
                await SystemTestKit.sleep(0.05)
                // 定时器按真实时间约 0.2 秒后触发；触发时注入的时钟已越过截止时间。
                clock.mutate { $0 = start.addingTimeInterval(0.3) }
                await SystemTestKit.sleep(0.4)
                t.expectEqual(events.value, [NetworkChangeEvent(reason: .wake, date: start)])
                // 时钟不前进时定时器触发也不输出。
                observer.noteRawChange(.network)
                await SystemTestKit.sleep(0.4)
                t.expectEqual(events.value.count, 1)
                clock.mutate { $0 = start.addingTimeInterval(1) }
                await SystemTestKit.sleep(0.4)
                t.expectEqual(events.value.last, NetworkChangeEvent(reason: .network, date: start.addingTimeInterval(0.3)))
            },
            TestCase("睡眠立即回调，唤醒与网络变化合并", timeout: 5) { t in
                let observer = makeObserver()
                let events = collecting(observer)
                defer { observer.stop() }
                observer.noteRawChange(.sleep)
                await SystemTestKit.sleep(0.05)
                t.expectEqual(events.value.map(\.reason), [.sleep])
                observer.noteRawChange(.network)   // 入睡过程中的变化，忽略
                observer.noteRawChange(.wake)
                observer.noteRawChange(.network)
                await SystemTestKit.sleep(0.5)
                t.expectEqual(events.value.map(\.reason), [.sleep, .wake])
            },
            TestCase("stop 后不再回调", timeout: 5) { t in
                let observer = makeObserver()
                let events = collecting(observer)
                observer.noteRawChange(.network)
                observer.stop()
                observer.noteRawChange(.network)
                await SystemTestKit.sleep(0.5)
                t.expectEqual(events.value.count, 0)
                t.expect(!observer.isRunning)
            },
            TestCase("重复 start 替换回调", timeout: 5) { t in
                let observer = makeObserver()
                let old = collecting(observer)
                let new = collecting(observer)
                defer { observer.stop() }
                observer.noteRawChange(.network)
                await SystemTestKit.sleep(0.5)
                t.expectEqual(old.value.count, 0)
                t.expectEqual(new.value.count, 1)
            },
            TestCase("回调中调用 stop 不死锁", timeout: 5) { t in
                let observer = makeObserver()
                let count = SystemTestKit.Box(0)
                observer.start { [weak observer] _ in
                    count.mutate { $0 += 1 }
                    observer?.stop()
                }
                observer.noteRawChange(.sleep)
                await SystemTestKit.sleep(0.2)
                t.expectEqual(count.value, 1)
                t.expect(!observer.isRunning)
            },
            TestCase("系统事件源反复安装与拆除不泄漏", timeout: 15) { t in
                weak var weakObserver: SystemNetworkChangeObserver?
                do {
                    let observer = SystemNetworkChangeObserver()
                    weakObserver = observer
                    for _ in 0..<20 {
                        observer.start { _ in }
                        t.expectEqual(observer.activeSources, .all)
                        t.expect(observer.isRunning)
                        observer.stop()
                        t.expectEqual(observer.activeSources, [])
                    }
                    observer.stop()
                    observer.start { _ in }
                    observer.start { _ in }
                    observer.stop()
                }
                // 给 NWPathMonitor 等异步释放留一点时间。
                await SystemTestKit.sleep(0.2)
                t.expect(weakObserver == nil, "停止后观察者应被释放")
            },
            TestCase("未 stop 直接释放时由 deinit 拆除", timeout: 5) { t in
                weak var weakObserver: SystemNetworkChangeObserver?
                do {
                    let observer = SystemNetworkChangeObserver()
                    weakObserver = observer
                    observer.start { _ in }
                }
                await SystemTestKit.sleep(0.2)
                t.expect(weakObserver == nil, "事件源只弱引用观察者")
            },
        ])
    }
}
