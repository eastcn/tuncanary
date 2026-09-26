import Foundation

/// mihomo 的 fake-ip 过滤名单匹配。支持的写法：
/// - `example.com`：只匹配该域名。
/// - `*.example.com`：`*` 匹配恰好一段，可以出现在任意位置。
/// - `+.example.com`：匹配该域名及其全部子域名。
/// - `.example.com`：匹配全部子域名，不含该域名本身。
/// `geosite:`、`rule-set:` 等引用外部列表的条目无法在本地判断。
public enum FakeIPFilter {
    public enum Result: Sendable, Equatable {
        /// 探针域名会拿到 fake-ip。
        case fakeIP
        /// 探针域名被排除，系统解析本就返回真实地址。
        case excluded(pattern: String?)
        /// 名单含外部列表，无法确认。
        case uncertain(entries: [String])
    }

    /// 判断 `host` 在该名单和模式下是否会分配 fake-ip。
    public static func evaluate(host: String, filter: [String]?, mode: String?) -> Result {
        let whitelist = mode?.lowercased() == "whitelist"
        let entries = filter ?? []
        let external = entries.filter { $0.contains(":") }
        let matched = entries.first { !$0.contains(":") && matches(host: host, pattern: $0) }
        if whitelist {
            // 白名单模式：只有名单内的域名分配 fake-ip。
            if matched != nil { return .fakeIP }
            return external.isEmpty ? .excluded(pattern: nil) : .uncertain(entries: external)
        }
        if let matched { return .excluded(pattern: matched) }
        return external.isEmpty ? .fakeIP : .uncertain(entries: external)
    }

    public static func matches(host: String, pattern: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var pattern = pattern.lowercased().trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !pattern.isEmpty else { return false }
        let hostLabels = host.split(separator: ".").map(String.init)
        if pattern.hasPrefix("+.") {
            pattern.removeFirst(2)
            let base = pattern.split(separator: ".").map(String.init)
            return hostLabels.count >= base.count && labelsMatch(Array(hostLabels.suffix(base.count)), base)
        }
        if pattern.hasPrefix(".") {
            pattern.removeFirst()
            let base = pattern.split(separator: ".").map(String.init)
            return hostLabels.count > base.count && labelsMatch(Array(hostLabels.suffix(base.count)), base)
        }
        let labels = pattern.split(separator: ".").map(String.init)
        return labels.count == hostLabels.count && labelsMatch(hostLabels, labels)
    }

    private static func labelsMatch(_ host: [String], _ pattern: [String]) -> Bool {
        zip(host, pattern).allSatisfy { $1 == "*" || $0 == $1 }
    }
}
