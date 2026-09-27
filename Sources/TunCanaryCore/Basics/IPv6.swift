import Darwin
import Foundation

/// IPv6 地址（16 字节，网络字节序）。只用于展示与网段判断。
public struct IPv6: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    /// - Parameter bytes: 必须是 16 字节，否则返回 nil。
    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// 解析文本形式，例如 `2001:db8::1`。不接受区域标识（`%en0`）和网段写法。
    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains("%"), !text.contains("/") else { return nil }
        var address = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        self.init(address)
    }

    public init(_ address: in6_addr) {
        var copy = address
        bytes = withUnsafeBytes(of: &copy) { Array($0) }
    }

    /// 标准压缩写法（RFC 5952），由 `inet_ntop` 生成。
    public var description: String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        return String(cString: buffer)
    }

    /// 是否为 IPv4 映射地址（`::ffff:0:0/96`）。macOS 的 `getaddrinfo(AF_INET6)` 在没有 AAAA 记录时
    /// 会把 A 记录映射成这种地址返回，它不代表真正的 AAAA 记录。
    public var isIPv4Mapped: Bool {
        bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
    }

    /// 是否为全局单播地址（`2000::/3`）。链路本地、ULA、回环等都不算。
    public var isGlobalUnicast: Bool {
        bytes[0] & 0xE0 == 0x20
    }
}

/// IPv6 网段，例如 Clash 配置中的 `fake-ip-range6`。
public struct IPv6CIDR: Hashable, Sendable, CustomStringConvertible {
    public let address: IPv6
    public let prefixLength: Int

    public init?(address: IPv6, prefixLength: Int) {
        guard (0...128).contains(prefixLength) else { return nil }
        self.address = address
        self.prefixLength = prefixLength
    }

    /// 严格解析 `地址/前缀长度`。
    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespaces)
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let ip = IPv6(String(pieces[0])),
              !pieces[1].isEmpty, pieces[1].count <= 3, pieces[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let length = Int(pieces[1]) else { return nil }
        self.init(address: ip, prefixLength: length)
    }

    public func contains(_ ip: IPv6) -> Bool {
        var remaining = prefixLength
        for index in 0..<16 where remaining > 0 {
            let bits = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if address.bytes[index] & mask != ip.bytes[index] & mask { return false }
            remaining -= bits
        }
        return true
    }

    public var description: String {
        "\(address)/\(prefixLength)"
    }
}
