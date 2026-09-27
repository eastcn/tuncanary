import Darwin
import Foundation
import TunCanaryCore
import TunCanaryProbe

/// TCP 连接探测：只用本机回环，不访问外部网络。
enum TCPConnectProberTests {
    /// 在 127.0.0.1 上监听一个随机端口，返回 (fd, 端口)。
    static func listen() throws -> (Int32, Int) {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else { close(fd); throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }

    static var suite: TestSuite {
        TestSuite("Probe.TCPConnect", [
            TestCase("端口在监听：可达，带延迟", timeout: 5) { t in
                let (fd, port) = try listen()
                defer { close(fd) }
                let outcome = await TCPConnectProber.probe(host: "127.0.0.1", port: port, timeout: 2)
                t.expectEqual(outcome.category, .reachable)
                t.expect(outcome.latency != nil)
                t.expectNil(outcome.detail)
            },
            TestCase("端口拒绝连接：路径可达，记为可达", timeout: 5) { t in
                let (fd, port) = try listen()
                close(fd)
                let outcome = await TCPConnectProber.probe(host: "127.0.0.1", port: port, timeout: 2)
                t.expectEqual(outcome.category, .reachable)
                t.expectEqual(outcome.detail, "端口拒绝连接，路径可达")
            },
            TestCase("站点探测器按 tcp:// 分派到 TCP 探测", timeout: 5) { t in
                let (fd, port) = try listen()
                defer { close(fd) }
                let site = SiteCatalog.tailnet(target: TailnetTarget("127.0.0.1:\(port)")!)
                let result = await URLSessionSiteProber().probe(site: site, attempts: 1, timeout: 2)
                t.expectEqual(result.category, .reachable)
                t.expect(result.medianLatency != nil)
            },
        ])
    }
}
