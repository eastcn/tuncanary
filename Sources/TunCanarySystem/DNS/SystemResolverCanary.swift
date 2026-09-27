import Darwin
import Foundation
import TunCanaryCore

/// 通过系统解析器（`getaddrinfo`）查询 canary 域名，带超时。A（AF_INET）与 AAAA（AF_INET6）分开查询。
///
/// `getaddrinfo` 无法取消：超时后立即返回失败，查询线程在后台自然结束。
/// 为避免 DNS 长时间无响应时后台线程越积越多，同一地址族上一次查询未返回前不会发起新查询。
public final class SystemResolverCanary: @unchecked Sendable {
    public let host: String
    public let timeout: TimeInterval

    private let lock = NSLock()
    private var inFlight = false
    private var inFlightIPv6 = false

    public init(host: String = PulseConstants.canaryHost, timeout: TimeInterval = PulseConstants.commandTimeout) {
        self.host = host
        self.timeout = timeout
    }

    /// 上一次 A 查询是否仍未返回。
    public var isLookupInFlight: Bool {
        lock.synchronized { inFlight }
    }

    /// 查询 A 记录。
    /// - Parameter host: 本次查询的域名；为 nil 时用初始化时的域名。
    public func resolve(host: String? = nil) async -> CanaryResult {
        await run(flag: \.inFlight, busy: .failed(reason: "上一次系统解析仍未返回"),
                  timedOut: { .failed(reason: $0) }) { [host = host ?? self.host] in Self.lookup(host) }
    }

    /// 查询 AAAA 记录。只作证据，失败不影响 A 查询。
    public func resolveIPv6(host: String? = nil) async -> CanaryIPv6Result {
        await run(flag: \.inFlightIPv6, busy: .failed(reason: "上一次 AAAA 解析仍未返回"),
                  timedOut: { .failed(reason: $0) }) { [host = host ?? self.host] in Self.lookupIPv6(host) }
    }

    private func run<Result: Sendable>(
        flag: ReferenceWritableKeyPath<SystemResolverCanary, Bool>,
        busy: Result,
        timedOut: @escaping @Sendable (String) -> Result,
        body: @escaping @Sendable () -> Result
    ) async -> Result {
        let started: Bool = lock.synchronized {
            if self[keyPath: flag] { return false }
            self[keyPath: flag] = true
            return true
        }
        guard started else { return busy }

        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            DispatchQueue.global(qos: .utility).async { [self] in
                let result = body()
                lock.synchronized { self[keyPath: flag] = false }
                if once.claim() { continuation.resume(returning: result) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.claim() {
                    let seconds = timeout == timeout.rounded() ? String(Int(timeout)) : String(format: "%.1f", timeout)
                    continuation.resume(returning: timedOut("系统解析超时（\(seconds) 秒）"))
                }
            }
        }
    }

    /// 阻塞查询 IPv6 地址（去重，保持顺序）。没有 AAAA 记录时返回 `.noRecord`。
    /// 系统把 A 记录映射成的 `::ffff:a.b.c.d` 不算 AAAA 记录，会被丢弃。
    public static func lookupIPv6(_ host: String) -> CanaryIPv6Result {
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, nil, &hints, &list)
        if code == EAI_NONAME || code == EAI_NODATA { return .noRecord }
        guard code == 0 else {
            return .failed(reason: describe(code))
        }
        defer { freeaddrinfo(list) }

        var addresses: [IPv6] = []
        var cursor = list
        while let entry = cursor {
            if entry.pointee.ai_family == AF_INET6, let address = entry.pointee.ai_addr {
                let ip = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    IPv6(pointer.pointee.sin6_addr)
                }
                if !ip.isIPv4Mapped && !addresses.contains(ip) { addresses.append(ip) }
            }
            cursor = entry.pointee.ai_next
        }
        return addresses.isEmpty ? .noRecord : .resolved(addresses)
    }

    /// 阻塞查询 IPv4 地址（去重，保持顺序）。
    public static func lookup(_ host: String) -> CanaryResult {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, nil, &hints, &list)
        guard code == 0 else {
            return .failed(reason: describe(code))
        }
        defer { freeaddrinfo(list) }

        var addresses: [IPv4] = []
        var cursor = list
        while let entry = cursor {
            if entry.pointee.ai_family == AF_INET, let address = entry.pointee.ai_addr {
                let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    IPv4(rawValue: UInt32(bigEndian: pointer.pointee.sin_addr.s_addr))
                }
                if !addresses.contains(ip) { addresses.append(ip) }
            }
            cursor = entry.pointee.ai_next
        }
        return .resolved(addresses)
    }

    /// getaddrinfo 错误码的中文说明。
    static func describe(_ code: Int32) -> String {
        switch code {
        case EAI_NONAME: return "域名无法解析（EAI_NONAME）"
        case EAI_AGAIN: return "解析器暂时不可用（EAI_AGAIN）"
        case EAI_FAIL: return "解析失败（EAI_FAIL）"
        case EAI_SYSTEM: return "系统错误（\(errnoDescription())）"
        default: return "getaddrinfo 错误 \(code)：\(String(cString: gai_strerror(code)))"
        }
    }
}
