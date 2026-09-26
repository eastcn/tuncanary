import Foundation

/// 代理 TUN 的配置：从 Clash Verge 配置中提取的字段，或手动模式下用户填写的值。
/// 只包含判定所需的字段，不含 secret、订阅或节点信息。
public struct ClashConfig: Sendable, Equatable {
    /// `verge.yaml` 的 `enable_tun_mode`。
    public var vergeTunModeEnabled: Bool?
    /// `clash-verge.yaml` 的 `tun.enable`。
    public var tunEnabled: Bool?
    /// `clash-verge.yaml` 的 `tun.device`，只作提示。
    public var tunDevice: String?
    /// `dns.listen` 中的端口。
    public var dnsListenPort: Int?
    /// `dns.enhanced-mode`，例如 `fake-ip`。
    public var dnsEnhancedMode: String?
    /// `dns.fake-ip-range`，例如 `198.18.0.1/16`。
    public var fakeIPRange: IPv4CIDR?
    /// `dns.fake-ip-filter`：这些域名不分配 fake-ip（白名单模式下相反）。未配置时为 nil。
    public var fakeIPFilter: [String]?
    /// `dns.fake-ip-filter-mode`：`blacklist`（默认）或 `whitelist`。
    public var fakeIPFilterMode: String?
    /// 是否来自手动模式（不读取客户端配置，TUN 是否运行只看接口和进程）。
    public var isManual: Bool = false
    /// 手动模式下的核心进程名；为 nil 时不检查进程。
    public var coreProcessName: String?

    public init(
        vergeTunModeEnabled: Bool? = nil,
        tunEnabled: Bool? = nil,
        tunDevice: String? = nil,
        dnsListenPort: Int? = nil,
        dnsEnhancedMode: String? = nil,
        fakeIPRange: IPv4CIDR? = nil
    ) {
        self.vergeTunModeEnabled = vergeTunModeEnabled
        self.tunEnabled = tunEnabled
        self.tunDevice = tunDevice
        self.dnsListenPort = dnsListenPort
        self.dnsEnhancedMode = dnsEnhancedMode
        self.fakeIPRange = fakeIPRange
    }

    /// 手动模式：按用户填写的 fake-ip 网段、DNS 端口和核心进程名构造。
    public static func manual(_ manual: ManualProxyConfig) -> ClashConfig {
        var config = ClashConfig(dnsListenPort: manual.dnsPort, dnsEnhancedMode: "fake-ip",
                                 fakeIPRange: manual.fakeIPNetwork)
        config.isManual = true
        let name = manual.coreProcessName.trimmingCharacters(in: .whitespaces)
        config.coreProcessName = name.isEmpty ? nil : name
        return config
    }

    /// 是否为 fake-ip 模式。
    public var isFakeIPMode: Bool {
        dnsEnhancedMode?.lowercased() == "fake-ip"
    }

    /// TUN 配置是否开启：已读到的开关全为 true 才算开启；任一为 false 即关闭；都没读到为 nil。
    public var tunConfigured: Bool? {
        let known = [vergeTunModeEnabled, tunEnabled].compactMap { $0 }
        guard !known.isEmpty else { return nil }
        return known.allSatisfy { $0 }
    }
}

/// Clash Verge 配置解析器。实现极简的行式 YAML 读取：只支持顶层键和一层缩进子键，
/// 只保留白名单中的字段，其余内容（含 secret）读过即丢弃。
public enum ClashConfigParser {
    static let vergeKeys: Set<String> = ["enable_tun_mode"]
    static let clashKeys: Set<String> = [
        "tun.enable", "tun.device", "dns.listen", "dns.enhanced-mode", "dns.fake-ip-range", "dns.fake-ip-filter-mode",
    ]

    /// 解析两份配置文本；任一为 nil 时对应字段保持 nil。
    public static func parse(vergeYAML: String?, clashVergeYAML: String?) -> ClashConfig {
        var config = ClashConfig()
        if let verge = vergeYAML {
            let values = scan(verge, wanted: vergeKeys)
            config.vergeTunModeEnabled = values["enable_tun_mode"].flatMap(parseBool)
        }
        if let clash = clashVergeYAML {
            let values = scan(clash, wanted: clashKeys)
            config.tunEnabled = values["tun.enable"].flatMap(parseBool)
            config.tunDevice = values["tun.device"].flatMap { $0.isEmpty ? nil : $0 }
            config.dnsListenPort = values["dns.listen"].flatMap(parsePort)
            config.dnsEnhancedMode = values["dns.enhanced-mode"].flatMap { $0.isEmpty ? nil : $0 }
            config.fakeIPRange = values["dns.fake-ip-range"].flatMap { IPv4CIDR($0) }
            config.fakeIPFilterMode = values["dns.fake-ip-filter-mode"].flatMap { $0.isEmpty ? nil : $0.lowercased() }
            config.fakeIPFilter = scanList(clash, top: "dns", key: "fake-ip-filter")
        }
        return config
    }

    /// 行式扫描，只返回 `wanted` 中的路径（`top` 或 `top.child`）。
    public static func scan(_ text: String, wanted: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        var currentTop: String?
        var childIndent: Int?

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed == "---" || trimmed == "..." {
                currentTop = nil
                continue
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count

            if indent == 0 {
                // 顶层列表项（如 `- name: x`）属于上一个键，忽略。
                if trimmed.hasPrefix("-") { continue }
                guard let (key, value) = splitKeyValue(trimmed) else {
                    currentTop = nil
                    continue
                }
                currentTop = key
                childIndent = nil
                if wanted.contains(key), !value.isEmpty { result[key] = value }
                continue
            }

            guard let top = currentTop else { continue }
            if childIndent == nil { childIndent = indent }
            // 只读第一层子键，更深的缩进与列表项忽略。
            guard indent == childIndent, !trimmed.hasPrefix("-") else { continue }
            guard let (key, value) = splitKeyValue(trimmed) else { continue }
            let path = top + "." + key
            if wanted.contains(path) { result[path] = value }
        }
        return result
    }

    /// 读取一层子键下的字符串列表，支持块列表（`- item`，缩进可与子键相同）和行内列表（`[a, b]`）。
    /// 子键不存在时返回 nil。
    public static func scanList(_ text: String, top: String, key: String) -> [String]? {
        var inTop = false
        var childIndent: Int?
        var collecting = false
        var items: [String]?
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            if indent == 0 {
                if collecting && trimmed.hasPrefix("-") { continue }
                collecting = false
                inTop = splitKeyValue(trimmed)?.0 == top
                childIndent = nil
                continue
            }
            guard inTop else { continue }
            if childIndent == nil { childIndent = indent }
            if collecting {
                if trimmed.hasPrefix("-") && indent >= childIndent! {
                    let value = cleanScalar(trimmed.dropFirst())
                    if !value.isEmpty { items?.append(value) }
                    continue
                }
                if indent > childIndent! { continue }
                collecting = false
            }
            guard indent == childIndent, !trimmed.hasPrefix("-"), let (name, value) = splitKeyValue(trimmed) else { continue }
            guard name == key else { continue }
            if value.hasPrefix("[") {
                let inner = value.dropFirst().prefix { $0 != "]" }
                items = inner.split(separator: ",").map { cleanScalar($0) }.filter { !$0.isEmpty }
            } else {
                items = []
                collecting = true
            }
        }
        return items
    }

    /// 拆分 `key: value`。冒号须后接空白或位于行尾，且不在引号内。
    static func splitKeyValue(_ line: String) -> (String, String)? {
        var inSingle = false
        var inDouble = false
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "'" && !inDouble {
                inSingle.toggle()
            } else if char == "\"" && !inSingle {
                inDouble.toggle()
            } else if char == ":" && !inSingle && !inDouble {
                let next = line.index(after: index)
                if next == line.endIndex || line[next] == " " || line[next] == "\t" {
                    let key = unquote(line[..<index].trimmingCharacters(in: .whitespaces))
                    guard !key.isEmpty else { return nil }
                    let value = cleanScalar(line[next...])
                    return (key, value)
                }
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// 去掉引号或行尾注释。
    static func cleanScalar(_ raw: Substring) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return "" }
        if first == "\"" || first == "'" {
            let rest = text.dropFirst()
            if let end = rest.firstIndex(of: first) {
                return String(rest[..<end])
            }
            return String(rest)
        }
        if let commentRange = text.range(of: " #") {
            return text[..<commentRange.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return text }
        return String(text.dropFirst().dropLast())
    }

    static func parseBool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: return nil
        }
    }

    /// 从 `0.0.0.0:7874`、`:7874`、`[::]:7874` 等写法中取端口。
    public static func parsePort(_ text: String) -> Int? {
        let candidate: Substring
        if let colon = text.lastIndex(of: ":") {
            candidate = text[text.index(after: colon)...]
        } else {
            candidate = Substring(text)
        }
        guard !candidate.isEmpty, candidate.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(candidate), (1...65535).contains(port) else { return nil }
        return port
    }
}
