import Darwin
import Foundation
import TunCanaryCore
import TunCanarySystem

/// 返回固定结果的站点探测桩。
private struct FixedProber: SiteProbing {
    let outcome: RequestOutcome

    func probe(site: Site, attempts: Int, timeout: TimeInterval) async -> SiteResult {
        SiteAggregator.aggregate(site: site, outcomes: [outcome], checkedAt: Date())
    }
}

/// 在临时 unix socket 上模拟 mihomo 控制接口：`/logs` 以分块传输推送日志，`/proxies/*/delay` 返回延迟。
private final class FakeMihomo: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private let logs: [String]
    private let delayBody: String
    private let lock = NSLock()
    private var requests: [String] = []

    init(logs: [String], delayBody: String = #"{"delay":321}"#) throws {
        path = NSTemporaryDirectory() + "tc-\(UUID().uuidString.prefix(8)).sock"
        self.logs = logs
        self.delayBody = delayBody
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { throw POSIXError(.EIO) }
        Thread.detachNewThread { [self] in serve() }
    }

    var receivedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func stop() {
        close(fd)
        unlink(path)
    }

    private func serve() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = recv(client, &buffer, buffer.count, 0)
            let request = String(decoding: buffer[0..<max(0, count)], as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            lock.lock()
            requests.append(path)
            lock.unlock()
            func write(_ text: String) {
                _ = text.utf8CString.withUnsafeBufferPointer { send(client, $0.baseAddress, $0.count - 1, 0) }
            }
            if path.hasPrefix("/logs") {
                write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n")
                // 等请求方发出探测后再推送日志；把一条日志拆成两块，检验分块拼接。
                usleep(300_000)
                for (index, log) in logs.enumerated() {
                    let json = #"{"type":"info","payload":"\#(log)"}"# + "\n"
                    let bytes = Array(json.utf8)
                    let parts = index == 0 ? [Array(bytes[..<10]), Array(bytes[10...])] : [bytes]
                    for part in parts {
                        write(String(part.count, radix: 16) + "\r\n")
                        _ = part.withUnsafeBufferPointer { send(client, $0.baseAddress, $0.count, 0) }
                        write("\r\n")
                    }
                }
                usleep(1_500_000)
            } else {
                write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(delayBody.utf8.count)\r\n\r\n\(delayBody)")
            }
            close(client)
        }
    }
}

/// 控制接口定位、分块解码和诊断流程。只用临时 unix socket，不访问网络。
enum MihomoControllerTests {
    static var suite: TestSuite {
        TestSuite("System.MihomoController", [
            TestCase("从进程参数中取 socket 路径") { t in
                t.expectEqual(MihomoController.socketArgument(
                    ["-d", "/tmp/runtime", "-f", "/tmp/config.yaml", "-ext-ctl-unix", "/var/run/example/mihomo.sock"]),
                              "/var/run/example/mihomo.sock")
                t.expectEqual(MihomoController.socketArgument(["--ext-ctl-unix=/tmp/a.sock"]), "/tmp/a.sock")
                t.expectNil(MihomoController.socketArgument(["-ext-ctl-unix"]))
                t.expectNil(MihomoController.socketArgument(["-d", "/tmp"]))
            },
            TestCase("诊断：抓到本进程的连接，复测失败时测节点延迟", timeout: 10) { t in
                let server = try FakeMihomo(logs: [
                    "[TCP] 198.18.0.1:1(OtherApp) --> example.com:443 match DomainSuffix(example.com) using 组[其他节点]",
                    "[TCP] 198.18.0.1:2(TunCanarySelfTest) --> example.com:443 match DomainSuffix(example.com) using 组[节点 A]",
                    "[TCP] dial 组 (match DomainSuffix/example.com) 198.18.0.1:2(TunCanarySelfTest) --> example.com:443 error: i/o timeout",
                ])
                defer { server.stop() }
                let site = Site(id: "example", name: "Example", group: .overseas,
                                url: URL(string: "https://example.com/")!, isKey: true, inLightProbe: true)
                let diagnoser = ProxyDiagnoser(prober: FixedProber(outcome: .failure(.timeout)),
                                               processName: "TunCanarySelfTest", probeTimeout: 1,
                                               locate: { .success(MihomoController(socketPath: server.path)) })
                let diagnosis = await diagnoser.diagnose(site: site, tunRunning: true, manual: false)
                guard case .proxied(let connection, let viaTun) = diagnosis.route else {
                    t.fail("应找到连接：\(diagnosis.route)")
                    return
                }
                t.expect(viaTun)
                t.expectEqual(connection.error, "i/o timeout")
                t.expectEqual(connection.rule, "DomainSuffix(example.com)")
                t.expectEqual(diagnosis.nodeDelay, .milliseconds(321))
                let delayRequest = server.receivedPaths.first { $0.hasPrefix("/proxies/") }
                // 测的是匹配记录里的具体节点，不是拨号记录里的策略组。
                t.expectEqual(connection.node, "节点 A")
                t.expectEqual(delayRequest?.components(separatedBy: "/delay").first, "/proxies/%E8%8A%82%E7%82%B9%20A")
            },
            TestCase("诊断：日志中没有本进程连接；找不到控制接口", timeout: 10) { t in
                let server = try FakeMihomo(logs: [
                    "[TCP] 198.18.0.1:1(OtherApp) --> example.com:443 match DomainSuffix(example.com) using 组[其他节点]",
                ])
                defer { server.stop() }
                let site = Site(id: "example", name: "Example", group: .overseas,
                                url: URL(string: "https://example.com/")!, isKey: true, inLightProbe: true)
                let missing = await ProxyDiagnoser(prober: FixedProber(outcome: .failure(.timeout)),
                                                   processName: "TunCanarySelfTest", probeTimeout: 1,
                                                   locate: { .success(MihomoController(socketPath: server.path)) })
                    .diagnose(site: site, tunRunning: false, manual: true)
                t.expectEqual(missing.route, .notInProxy(tunRunning: false))
                t.expectNil(missing.nodeDelay)
                t.expect(missing.manual)

                let unavailable = await ProxyDiagnoser(prober: FixedProber(outcome: .failure(.timeout)),
                                                       probeTimeout: 1, locate: { .failure(.notFound) })
                    .diagnose(site: site, tunRunning: true, manual: false)
                t.expectEqual(unavailable.route, .unavailable(reason: "未找到 Clash Verge Rev 的控制接口"))
                t.expectEqual(unavailable.outcome.category, .timeout)
            },
        ])
    }
}
