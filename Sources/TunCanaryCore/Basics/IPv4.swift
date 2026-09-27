import Foundation

/// IPv4 地址（不依赖 Network 框架，避免与 `Network.IPv4Address` 重名）。
public struct IPv4: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    /// 主机字节序的 32 位值。
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        rawValue = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    /// 严格解析点分十进制 `a.b.c.d`。
    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = IPv4.parseOctet(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        rawValue = value
    }

    /// 解析 0–255 的十进制段。
    static func parseOctet<S: StringProtocol>(_ part: S) -> UInt8? {
        guard !part.isEmpty, part.count <= 3,
              part.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(part), number <= 255 else { return nil }
        return UInt8(number)
    }

    public var octets: [UInt8] {
        [UInt8(rawValue >> 24 & 0xFF), UInt8(rawValue >> 16 & 0xFF),
         UInt8(rawValue >> 8 & 0xFF), UInt8(rawValue & 0xFF)]
    }

    public var description: String {
        octets.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: IPv4, rhs: IPv4) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 是否属于私有或本地网段（脱敏时只保留首段）：
    /// 10/8、172.16/12、192.168/16、100.64/10（CGNAT，含 Tailscale）、169.254/16。
    public var isPrivateForRedaction: Bool {
        IPv4CIDR.redactedNetworks.contains { $0.contains(self) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = IPv4(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无效的 IPv4 地址：\(text)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// IPv4 CIDR 网段。保留书写时的地址（允许主机位非零，如 `198.18.0.1/16`），判断包含关系时按掩码比较。
public struct IPv4CIDR: Hashable, Sendable, CustomStringConvertible {
    /// 书写时的地址，可能含非零主机位。
    public let address: IPv4
    public let prefixLength: Int

    public init?(address: IPv4, prefixLength: Int) {
        guard (0...32).contains(prefixLength) else { return nil }
        self.address = address
        self.prefixLength = prefixLength
    }

    /// 严格解析 `a.b.c.d/n`（设置项与 Clash 配置使用）。
    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespaces)
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let ip = IPv4(String(pieces[0])),
              !pieces[1].isEmpty, pieces[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let length = Int(pieces[1]) else { return nil }
        self.init(address: ip, prefixLength: length)
    }

    /// 解析 `netstat -rn` 的目的地列，支持缩写：
    /// `default` → 0.0.0.0/0；`10.1/16` → 10.1.0.0/16；`172.16` → 172.16.0.0/16；
    /// `128.0/1` → 128.0.0.0/1；`127.0.0.1` → /32。未写前缀时按给出的段数 ×8 推算。
    public init?(netstatDestination raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text == "default" {
            self.init(address: IPv4(rawValue: 0), prefixLength: 0)
            return
        }
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2 else { return nil }
        let parts = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard let octet = IPv4.parseOctet(part) else { return nil }
            octets.append(octet)
        }
        let length: Int
        if pieces.count == 2 {
            guard !pieces[1].isEmpty, pieces[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let parsed = Int(pieces[1]) else { return nil }
            length = parsed
        } else {
            length = octets.count * 8
        }
        while octets.count < 4 { octets.append(0) }
        self.init(address: IPv4(octets[0], octets[1], octets[2], octets[3]), prefixLength: length)
    }

    /// 网络掩码。
    public var mask: UInt32 {
        prefixLength == 0 ? 0 : UInt32.max << UInt32(32 - prefixLength)
    }

    /// 网络地址（主机位清零）。
    public var networkAddress: IPv4 {
        IPv4(rawValue: address.rawValue & mask)
    }

    /// 规范化后的网段（主机位清零）。
    public var normalized: IPv4CIDR {
        IPv4CIDR(address: networkAddress, prefixLength: prefixLength)!
    }

    public func contains(_ ip: IPv4) -> Bool {
        ip.rawValue & mask == address.rawValue & mask
    }

    public var description: String {
        "\(address)/\(prefixLength)"
    }

    /// Tailscale 使用的 CGNAT 网段 100.64.0.0/10。
    public static let tailscale = IPv4CIDR("100.64.0.0/10")!

    /// Clash 默认 fake-ip 所在的 198.18.0.0/15（基准测试保留段）。配置不可读时用于排除。
    public static let benchmarkFakeIP = IPv4CIDR("198.18.0.0/15")!

    /// 脱敏时视为私有的网段。
    static let redactedNetworks: [IPv4CIDR] = [
        IPv4CIDR("10.0.0.0/8")!,
        IPv4CIDR("172.16.0.0/12")!,
        IPv4CIDR("192.168.0.0/16")!,
        IPv4CIDR("100.64.0.0/10")!,
        IPv4CIDR("169.254.0.0/16")!,
    ]
}

extension IPv4CIDR: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = IPv4CIDR(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无效的 CIDR：\(text)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
