import Foundation

/// 从 VPN 状态文件中读出的字段。只包含适配器配置指定的四项，其余内容不进入模型。
public struct VPNStatus: Sendable, Equatable {
    /// 是否已连接。
    public var status: Bool?
    /// 是否正在连接。
    public var connecting: Bool?
    /// 隧道 IP。有的客户端断开后仍保留旧值，不能单独作为连接证据。
    public var tunnelIP: String?
    /// VPN 下发的 DNS，已规范化。
    public var dnsServers: [String]

    public init(status: Bool?, connecting: Bool?, tunnelIP: String?, dnsServers: [String]) {
        self.status = status
        self.connecting = connecting
        self.tunnelIP = tunnelIP
        self.dnsServers = DNSList.normalize(dnsServers)
    }

    public var tunnelIPv4: IPv4? {
        tunnelIP.flatMap { IPv4($0) }
    }
}

/// 一个适配器状态文件的读取结果。
public enum VPNStatusFileState: Sendable, Equatable {
    case notCollected
    /// 文件不存在。
    case missing
    /// 存在但不可读或格式错误。
    case unreadable(reason: String)
    case present(VPNStatus)

    public var status: VPNStatus? {
        if case .present(let status) = self { return status }
        return nil
    }
}

/// 状态文件解析错误。
public enum VPNStatusFileParseError: Error, Equatable, Sendable {
    case invalidJSON
    case noConfiguredField

    public var message: String {
        switch self {
        case .invalidJSON: return "状态文件不是有效的 JSON"
        case .noConfiguredField: return "状态文件中没有配置的字段"
        }
    }
}

/// 按适配器配置解析状态文件：只读取指定 JSON Pointer 处的值。
public enum VPNStatusFileParser {
    public static func parse(_ text: String, fields: VPNAdapterConfig.StatusFile) throws -> VPNStatus {
        try parse(Data(text.utf8), fields: fields)
    }

    public static func parse(_ data: Data, fields: VPNAdapterConfig.StatusFile) throws -> VPNStatus {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw VPNStatusFileParseError.invalidJSON
        }
        func value(_ pointer: String?) -> Any? {
            pointer.flatMap(JSONPointer.init).flatMap { $0.resolve(in: root) }
        }
        let connected = value(fields.connected)
        let connecting = value(fields.connecting)
        let tunnelIP = value(fields.tunnelIP)
        let dns = value(fields.dns)
        if !fields.pointers.isEmpty && [connected, connecting, tunnelIP, dns].allSatisfy({ $0 == nil }) {
            throw VPNStatusFileParseError.noConfiguredField
        }
        return VPNStatus(
            status: bool(connected),
            connecting: bool(connecting),
            tunnelIP: (tunnelIP as? String).flatMap { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            },
            dnsServers: dnsList(dns)
        )
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber:
            return number.boolValue
        case let text as String:
            switch text.lowercased() {
            case "true", "1", "yes", "connected": return true
            case "false", "0", "no", "disconnected": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    /// 逗号分隔的字符串，或字符串数组。
    static func dnsList(_ value: Any?) -> [String] {
        switch value {
        case let text as String:
            return DNSList.split(text)
        case let list as [Any]:
            return DNSList.normalize(list.compactMap { $0 as? String })
        default:
            return []
        }
    }
}
