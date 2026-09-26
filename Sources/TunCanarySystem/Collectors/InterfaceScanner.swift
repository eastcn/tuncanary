import Darwin
import Foundation
import TunCanaryCore

/// 网络接口扫描：`getifaddrs` 取名称、标志与 IPv4 地址。
public struct InterfaceScanner: Sendable {
    public init() {}

    /// 按首次出现的顺序返回全部接口（同名条目合并）。
    public func scan() throws -> [InterfaceInfo] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            throw SystemCollectionError("getifaddrs 失败（\(errnoDescription())）")
        }
        defer { freeifaddrs(head) }

        var order: [String] = []
        var table: [String: InterfaceInfo] = [:]
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let rawName = entry.pointee.ifa_name else { continue }
            let name = String(cString: rawName)
            let flags = entry.pointee.ifa_flags
            if table[name] == nil {
                order.append(name)
                table[name] = InterfaceInfo(
                    name: name,
                    isUp: flags & UInt32(IFF_UP) != 0,
                    ipv4Addresses: [],
                    flags: Self.flagNames(flags)
                )
            }
            if let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
                let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    IPv4(rawValue: UInt32(bigEndian: pointer.pointee.sin_addr.s_addr))
                }
                if table[name]?.ipv4Addresses.contains(ip) == false {
                    table[name]?.ipv4Addresses.append(ip)
                }
            }
        }
        return order.compactMap { table[$0] }
    }

    /// 与 `ifconfig` 一致的标志名。
    static let flagTable: [(UInt32, String)] = [
        (UInt32(IFF_UP), "UP"),
        (UInt32(IFF_BROADCAST), "BROADCAST"),
        (UInt32(IFF_DEBUG), "DEBUG"),
        (UInt32(IFF_LOOPBACK), "LOOPBACK"),
        (UInt32(IFF_POINTOPOINT), "POINTOPOINT"),
        (UInt32(IFF_NOTRAILERS), "SMART"),
        (UInt32(IFF_RUNNING), "RUNNING"),
        (UInt32(IFF_NOARP), "NOARP"),
        (UInt32(IFF_PROMISC), "PROMISC"),
        (UInt32(IFF_ALLMULTI), "ALLMULTI"),
        (UInt32(IFF_OACTIVE), "OACTIVE"),
        (UInt32(IFF_SIMPLEX), "SIMPLEX"),
        (UInt32(IFF_LINK0), "LINK0"),
        (UInt32(IFF_LINK1), "LINK1"),
        (UInt32(IFF_LINK2), "LINK2"),
        (UInt32(IFF_MULTICAST), "MULTICAST"),
    ]

    /// 把 `ifa_flags` 转成标志名列表，例如 `["UP", "POINTOPOINT", "RUNNING", "MULTICAST"]`。
    public static func flagNames(_ flags: UInt32) -> [String] {
        flagTable.compactMap { bit, name in flags & bit != 0 ? name : nil }
    }
}
