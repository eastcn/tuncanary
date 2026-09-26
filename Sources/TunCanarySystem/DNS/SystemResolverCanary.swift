import Darwin
import Foundation
import TunCanaryCore

/// 通过系统解析器（`getaddrinfo`，AF_INET）查询 canary 域名，带超时。
///
/// `getaddrinfo` 无法取消：超时后立即返回 `.failed`，查询线程在后台自然结束。
/// 为避免 DNS 长时间无响应时后台线程越积越多，上一次查询未返回前不会发起新查询。
public final class SystemResolverCanary: @unchecked Sendable {
    public let host: String
    public let timeout: TimeInterval

    private let lock = NSLock()
    private var inFlight = false

    public init(host: String = PulseConstants.canaryHost, timeout: TimeInterval = PulseConstants.commandTimeout) {
        self.host = host
        self.timeout = timeout
    }

    /// 上一次查询是否仍未返回。
    public var isLookupInFlight: Bool {
        lock.synchronized { inFlight }
    }

    /// - Parameter host: 本次查询的域名；为 nil 时用初始化时的域名。
    public func resolve(host: String? = nil) async -> CanaryResult {
        let started: Bool = lock.synchronized {
            if inFlight { return false }
            inFlight = true
            return true
        }
        guard started else {
            return .failed(reason: "上一次系统解析仍未返回")
        }

        let host = host ?? self.host
        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            DispatchQueue.global(qos: .utility).async { [self] in
                let result = Self.lookup(host)
                lock.synchronized { inFlight = false }
                if once.claim() { continuation.resume(returning: result) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.claim() {
                    let seconds = timeout == timeout.rounded() ? String(Int(timeout)) : String(format: "%.1f", timeout)
                    continuation.resume(returning: .failed(reason: "系统解析超时（\(seconds) 秒）"))
                }
            }
        }
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
