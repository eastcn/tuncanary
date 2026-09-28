import Foundation
import TunCanaryCore

enum EgressMonitoringTests {
    static let start = Date(timeIntervalSince1970: 1_790_500_000)
    static func sample(_ seconds: Double, ip: String = "203.0.113.1", family: EgressIPVersion = .ipv4,
                       country: String? = "US", failure: EgressIPFailure? = nil, age: Double = 0,
                       retryAfter: Date? = nil, target: EgressIPTarget = .claude) -> EgressObservation {
        let date = start.addingTimeInterval(seconds)
        return EgressObservation(result: EgressIPResult(target: target, checkedAt: date,
            ip: failure == nil ? ip : nil, ipVersion: failure == nil ? family : nil, location: nil, failure: failure, retryAfter: retryAfter),
            geo: country.map { EgressGeo(ip: ip, countryCode: $0, checkedAt: date.addingTimeInterval(-age)) })
    }
    static var suite: TestSuite {
        TestSuite("Core.EgressMonitoring", [
            TestCase("越界连续两次才通知，持续异常不重复，恢复一次") { t in
                var state = EgressMonitorState(); var config = EgressMonitoringSettings()
                config.allowedRegions["claude"] = ["JP", "SG"]
                t.expect(state.record(sample(0), settings: config).isEmpty)
                t.expectEqual(state.record(sample(300), settings: config).map(\.kind), [.regionViolation])
                t.expect(state.record(sample(600), settings: config).isEmpty)
                t.expectEqual(state.record(sample(900, country: "JP"), settings: config).map(\.kind), [.regionRecovered])
                t.expect(state.record(sample(1200, country: "SG"), settings: config).isEmpty)
            },
            TestCase("失败、地域未知、过期及采样空隙打断连续确认") { t in
                var config = EgressMonitoringSettings(); config.allowedRegions["claude"] = ["JP"]
                for middle in [sample(300, failure: .timeout), sample(300, country: nil), sample(300, age: 8 * 86400)] {
                    var state = EgressMonitorState()
                    _ = state.record(sample(0), settings: config)
                    t.expect(state.record(middle, settings: config).isEmpty)
                    t.expect(state.record(sample(600), settings: config).isEmpty)
                    t.expectEqual(state.record(sample(900), settings: config).map(\.kind), [.regionViolation])
                }
                var state = EgressMonitorState()
                _ = state.record(sample(0), settings: config)
                t.expect(state.record(sample(900), settings: config).isEmpty, "采样中断不能补齐连续次数")
                t.expect(state.summary(for: .claude, at: start.addingTimeInterval(900), interval: 300).observedSince == start.addingTimeInterval(900))
            },
            TestCase("IPv4 IPv6 分开比较；变化默认静默，开启才通知") { t in
                var state = EgressMonitorState(); var config = EgressMonitoringSettings()
                _ = state.record(sample(0), settings: config)
                _ = state.record(sample(300, ip: "2001:db8::1", family: .ipv6), settings: config)
                t.expect(state.record(sample(600, ip: "203.0.113.2"), settings: config).isEmpty)
                config.notifyIPChanges = true
                t.expectEqual(state.record(sample(900, ip: "2001:db8::2", family: .ipv6), settings: config).map(\.kind), [.ipChanged])
                let summary = state.summary(for: .claude, at: start.addingTimeInterval(900), interval: 300)
                t.expectEqual(summary.changes, 2)
                t.expectNil(state.summary(for: .claude, at: start.addingTimeInterval(1600), interval: 300).observedSince)
            },
            TestCase("429 Retry-After 与最小间隔同时生效；403 需人工恢复") { t in
                var state = EgressMonitorState(); let config = EgressMonitoringSettings()
                state.begin(.claude, at: start)
                _ = state.record(sample(0, failure: .httpStatus(429), retryAfter: start.addingTimeInterval(1800)), settings: config)
                t.expect(!state.isEligible(.claude, at: start.addingTimeInterval(300), interval: 300))
                state.resume(.claude)
                t.expect(!state.isEligible(.claude, at: start.addingTimeInterval(1799), interval: 300))
                t.expect(state.isEligible(.claude, at: start.addingTimeInterval(1800), interval: 300))
                _ = state.record(sample(1800, failure: .httpStatus(403)), settings: config)
                t.expect(!state.isEligible(.claude, at: start.addingTimeInterval(86400), interval: 300))
                state.resume(.claude)
                t.expect(state.isEligible(.claude, at: start.addingTimeInterval(86400), interval: 300))
            },
            TestCase("30 天到期清理，重启保留历史和告警冷却；写入失败可见") { t in
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("egress-test-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("history.json")
                var state = EgressMonitorState(); var config = EgressMonitoringSettings()
                config.allowedRegions["claude"] = ["JP"]
                _ = state.record(sample(0), settings: config)
                _ = state.record(sample(300), settings: config)
                _ = state.record(sample(600, failure: .httpStatus(429), retryAfter: start.addingTimeInterval(3600)), settings: config)
                let store = EgressHistoryStore(fileURL: file)
                t.expect(store.save(state, revision: 2))
                t.expect(store.save(EgressMonitorState(), revision: 1), "迟到的旧保存应被忽略")
                var restored = EgressHistoryStore(fileURL: file).load(at: start.addingTimeInterval(600))
                t.expectEqual(restored, state)
                t.expect(!restored.isEligible(.claude, at: start.addingTimeInterval(700), interval: 300))
                t.expect(restored.record(sample(900), settings: config).isEmpty, "重启后持续越界不重复通知")
                restored.prune(at: start.addingTimeInterval(31 * 86400))
                t.expect(restored.history.isEmpty)
                t.expect(!EgressHistoryStore(fileURL: directory).save(state), "不能把目录当作文件写入")
            },
            TestCase("自定义 JSON 响应头与地域配置往返；非法输入不能保存") { t in
                let header = try t.require(EgressIPTarget.endpoint(EgressEndpoint(name: "国内参考", url: URL(string: "https://echo.example.test/image.png")!, method: .header, selector: "x-request-ip")))
                let json = try t.require(EgressIPTarget.endpoint(EgressEndpoint(name: "备用", url: URL(string: "https://echo.example.test/json")!, method: .json, selector: "data.ip")))
                t.expectEqual(EgressIPTarget(rawValue: header.rawValue), header)
                let settings = AppSettings(egressTargets: [.cloudflare, header, json])
                t.expectEqual(settings.effectiveEgressTargets.count, 3, "相同主机不同端点独立保留")
                t.expectNil(EgressIPTarget.endpoint(EgressEndpoint(name: "坏接口", url: URL(string: "http://echo.example.test/ip")!, method: .json, selector: "data.ip")))
                t.expectNil(EgressIPTarget.endpoint(EgressEndpoint(name: "坏接口", url: URL(string: "https://user:pass@echo.example.test/ip")!, method: .header, selector: "x-ip")))
                t.expectNil(EgressIPTarget.endpoint(EgressEndpoint(name: "坏接口", url: URL(string: "https://echo.example.test/ip")!, method: .json, selector: "data..ip")))
                var config = EgressMonitoringSettings(); config.interval = 299
                t.expect(!config.isValid)
                t.expectEqual(config.effectiveInterval, 300)
            },
            TestCase("地域源冲突不误报，首次查询完成的时间偏差不导致未知") { t in
                var sample = sample(0)
                sample.geo?.checkedAt = start.addingTimeInterval(4)
                t.expect(sample.regionIsFresh)
                sample.result = EgressIPResult(target: .claude, checkedAt: start, ip: "203.0.113.1", ipVersion: .ipv4, location: "JP", failure: nil)
                t.expect(!sample.regionIsFresh)
            },
        ])
    }
}
