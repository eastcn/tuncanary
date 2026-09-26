import Foundation

/// 声明式 VPN 适配器配置。每个 JSON 文件描述一个 VPN 客户端：
/// 按可执行文件路径识别进程，可选读取状态文件中的指定字段，并给出识别隧道的线索。
///
/// ```json
/// {
///   "id": "example-vpn",
///   "name": "Example VPN",
///   "process": { "executablePaths": ["/Applications/Example VPN.app/Contents/MacOS/example-tunnel"] },
///   "statusFile": {
///     "path": "~/Library/Application Support/Example VPN/state.json",
///     "connected": "/session/active",
///     "tunnelIP": "/session/address",
///     "dns": "/session/resolvers"
///   },
///   "tunnel": { "cidr": "10.8.0.0/16", "minRoutes": 10 }
/// }
/// ```
public struct VPNAdapterConfig: Sendable, Equatable, Codable, Identifiable {
    /// 稳定 ID，只含字母、数字、`-` 和 `_`。
    public var id: String
    /// 界面显示名，例如 “Example VPN”。
    public var name: String
    public var process: ProcessMatch
    public var statusFile: StatusFile?
    public var tunnel: Tunnel?

    public struct ProcessMatch: Sendable, Equatable, Codable {
        /// 可执行文件的完整路径，支持 `~/` 开头。按 `proc_pidpath` 的结果精确比较，不看命令行。
        public var executablePaths: [String]

        public init(executablePaths: [String]) {
            self.executablePaths = executablePaths
        }
    }

    /// 状态文件（JSON）。字段用 JSON Pointer（RFC 6901）指定，未指定的字段不读取。
    public struct StatusFile: Sendable, Equatable, Codable {
        public var path: String
        /// 是否已连接（布尔值，或 `"true"`、`"1"` 等字符串）。
        public var connected: String?
        /// 是否正在连接。
        public var connecting: String?
        /// 隧道接口的 IPv4，用于识别隧道。
        public var tunnelIP: String?
        /// VPN 下发的 DNS：逗号分隔的字符串或字符串数组。
        public var dns: String?

        public init(path: String, connected: String? = nil, connecting: String? = nil,
                    tunnelIP: String? = nil, dns: String? = nil) {
            self.path = path
            self.connected = connected
            self.connecting = connecting
            self.tunnelIP = tunnelIP
            self.dns = dns
        }

        /// 已配置的字段指针。
        public var pointers: [String] {
            [connected, connecting, tunnelIP, dns].compactMap { $0 }
        }
    }

    public struct Tunnel: Sendable, Equatable, Codable {
        /// 隧道 IPv4 所在网段；状态文件不可用时据此识别。
        public var cidr: String?
        /// 状态文件和网段都无法识别时，按路由条数回退识别所需的最少条数。
        public var minRoutes: Int?

        public init(cidr: String? = nil, minRoutes: Int? = nil) {
            self.cidr = cidr
            self.minRoutes = minRoutes
        }
    }

    public init(id: String, name: String, process: ProcessMatch, statusFile: StatusFile? = nil, tunnel: Tunnel? = nil) {
        self.id = id
        self.name = name
        self.process = process
        self.statusFile = statusFile
        self.tunnel = tunnel
    }

    /// 解析后的隧道网段；未配置或非法时为 nil。
    public var tunnelNetwork: IPv4CIDR? {
        tunnel?.cidr.flatMap { IPv4CIDR($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 按路由条数回退识别的门槛。
    public var fallbackMinRoutes: Int {
        tunnel?.minRoutes ?? PulseConstants.vpnFallbackMinRoutes
    }

    /// 展开 `~/` 后的可执行文件路径。
    public func executablePaths(home: String) -> [String] {
        process.executablePaths.map { KnownPaths.expandTilde($0, home: home) }
    }

    /// 展开 `~/` 后的状态文件路径。
    public func statusFilePath(home: String) -> String? {
        statusFile.map { KnownPaths.expandTilde($0.path, home: home) }
    }
}

/// 适配器配置的校验错误。
public enum VPNAdapterConfigError: Error, Equatable, Sendable {
    case invalidJSON(String)
    case idInvalid
    case idDuplicate(String)
    case nameInvalid
    case executablePathsEmpty
    case executablePathInvalid(String)
    case statusFilePathInvalid
    case pointerInvalid(String)
    case tunnelCIDRInvalid(String)
    case minRoutesInvalid

    public var message: String {
        switch self {
        case .invalidJSON(let detail): return "不是有效的适配器配置（\(detail)）"
        case .idInvalid: return "id 须为 1–40 个字母、数字、- 或 _"
        case .idDuplicate(let id): return "id“\(id)”与其他适配器重复"
        case .nameInvalid: return "name 须为 1–40 个字符"
        case .executablePathsEmpty: return "process.executablePaths 至少填写一个路径"
        case .executablePathInvalid(let path): return "“\(path)”不是绝对路径或 ~/ 开头的路径"
        case .statusFilePathInvalid: return "statusFile.path 须为绝对路径或 ~/ 开头的路径"
        case .pointerInvalid(let pointer): return "“\(pointer)”不是有效的 JSON Pointer（须以 / 开头）"
        case .tunnelCIDRInvalid(let cidr): return "“\(cidr)”不是有效的 CIDR 网段"
        case .minRoutesInvalid: return "tunnel.minRoutes 须为 1–1000 的整数"
        }
    }
}

extension VPNAdapterConfig {
    /// 校验单个配置，返回全部错误；空数组表示通过。
    public func validate() -> [VPNAdapterConfigError] {
        var errors: [VPNAdapterConfigError] = []
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        if id.isEmpty || id.count > 40 || !id.unicodeScalars.allSatisfy(allowed.contains) {
            errors.append(.idInvalid)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || name.count > 40 { errors.append(.nameInvalid) }
        if process.executablePaths.isEmpty { errors.append(.executablePathsEmpty) }
        for path in process.executablePaths where !Self.isUsablePath(path) {
            errors.append(.executablePathInvalid(path))
        }
        if let file = statusFile {
            if !Self.isUsablePath(file.path) { errors.append(.statusFilePathInvalid) }
            for pointer in file.pointers where JSONPointer(pointer) == nil {
                errors.append(.pointerInvalid(pointer))
            }
        }
        if let cidr = tunnel?.cidr, IPv4CIDR(cidr.trimmingCharacters(in: .whitespaces)) == nil {
            errors.append(.tunnelCIDRInvalid(cidr))
        }
        if let minRoutes = tunnel?.minRoutes, !(1...1000).contains(minRoutes) {
            errors.append(.minRoutesInvalid)
        }
        return errors
    }

    static func isUsablePath(_ path: String) -> Bool {
        (path.hasPrefix("/") || path.hasPrefix("~/")) && path.count > 2 && !path.contains("\0")
    }
}

/// JSON Pointer（RFC 6901）。只用于读取，不支持 `-` 数组末尾标记。
public struct JSONPointer: Sendable, Equatable {
    public let tokens: [String]

    /// 空串表示整个文档；否则必须以 `/` 开头。
    public init?(_ text: String) {
        if text.isEmpty {
            tokens = []
            return
        }
        guard text.hasPrefix("/") else { return nil }
        tokens = text.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { token in
            token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
    }

    /// 在 `JSONSerialization` 解出的对象中取值；路径不存在时为 nil。
    public func resolve(in root: Any) -> Any? {
        var current: Any = root
        for token in tokens {
            if let object = current as? [String: Any] {
                guard let next = object[token] else { return nil }
                current = next
            } else if let array = current as? [Any] {
                guard let index = Int(token), token == String(index), array.indices.contains(index) else { return nil }
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }
}
