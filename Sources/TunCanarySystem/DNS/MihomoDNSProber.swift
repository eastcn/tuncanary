import Darwin
import Foundation
import TunCanaryCore

/// 一次 UDP DNS 查询的结果。
public enum DNSQueryOutcome: Sendable, Equatable {
    /// 收到 ID 匹配的应答。延迟单位为秒（发送到收到应答）。
    case answered(latency: TimeInterval, response: DNSResponse)
    /// 超时未收到应答。
    case timedOut
    /// 端口拒绝（收到 ICMP 端口不可达）。
    case refused
    /// 本地错误（创建 socket、地址无效等）。
    case failed(String)
}

/// 最小 UDP DNS 客户端（BSD socket，阻塞调用）。
public enum UDPDNSClient {
    /// 向 `host:port` 发送一个查询，最多等待 `timeout` 秒。
    /// ID 不匹配、不是应答或无法解析的报文会被丢弃并继续等待。
    public static func query(
        host: String,
        port: Int,
        name: String,
        type: UInt16 = DNSMessage.typeA,
        timeout: TimeInterval,
        id: UInt16 = UInt16.random(in: 0...UInt16.max)
    ) -> DNSQueryOutcome {
        guard (1...65535).contains(port) else { return .failed("端口无效：\(port)") }
        let message: [UInt8]
        do {
            message = try DNSMessage.encodeQuery(id: id, name: name, type: type)
        } catch {
            return .failed("查询名无效：\(name)")
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .failed("创建 socket 失败（\(errnoDescription())）") }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            return .failed("地址无效：\(host)")
        }
        // connect 后内核会把 ICMP 端口不可达报告为 ECONNREFUSED，端口未监听时可以立即返回。
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return .failed("connect 失败（\(errnoDescription())）") }

        let sentAt = Monotonic.now()
        let deadline = sentAt + max(0, timeout)
        let sent = message.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        if sent < 0 {
            return errno == ECONNREFUSED ? .refused : .failed("发送失败（\(errnoDescription())）")
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let remaining = deadline - Monotonic.now()
            if remaining <= 0 { return .timedOut }
            var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, Int32(max(1, (remaining * 1000).rounded(.up))))
            if ready < 0 {
                if errno == EINTR { continue }
                return .failed("poll 失败（\(errnoDescription())）")
            }
            if ready == 0 { continue }

            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            let receivedAt = Monotonic.now()
            if count < 0 {
                switch errno {
                case EINTR, EAGAIN: continue
                case ECONNREFUSED: return .refused
                default: return .failed("接收失败（\(errnoDescription())）")
                }
            }
            guard let response = try? DNSMessage.parseResponse(Array(buffer[0..<count])),
                  response.id == id, response.isResponse else { continue }
            return .answered(latency: receivedAt - sentAt, response: response)
        }
    }
}

/// 向本机 Mihomo DNS（`127.0.0.1:<dns.listen 端口>`）发送 UDP A 查询。
public struct MihomoDNSProber: Sendable {
    public var host: String
    public var queryName: String
    public var timeout: TimeInterval

    public init(
        host: String = PulseConstants.mihomoDNSHost,
        queryName: String = PulseConstants.canaryHost,
        timeout: TimeInterval = PulseConstants.mihomoDNSTimeout
    ) {
        self.host = host
        self.queryName = queryName
        self.timeout = timeout
    }

    /// 在后台队列执行查询。
    public func probe(port: Int) async -> MihomoDNSProbeResult {
        let prober = self
        return await Blocking.run { prober.probeBlocking(port: port) }
    }

    /// 阻塞查询。收到任何应答（含非 NOERROR）都算端口有响应。
    public func probeBlocking(port: Int) -> MihomoDNSProbeResult {
        Self.result(port: port, outcome: UDPDNSClient.query(host: host, port: port, name: queryName, timeout: timeout))
    }

    /// 把查询结果映射为模型。
    public static func result(port: Int, outcome: DNSQueryOutcome) -> MihomoDNSProbeResult {
        switch outcome {
        case .answered(let latency, let response):
            return .success(port: port, latency: latency, answers: response.ipv4Answers)
        case .timedOut, .refused, .failed:
            return .noResponse(port: port)
        }
    }
}
