import Foundation

/// 解析 `scutil --dns` 输出，区分普通段与 scoped 段。
public enum ScutilDNSParser {
    public static func parse(_ text: String) -> [Resolver] {
        var resolvers: [Resolver] = []
        var current: Resolver?
        var scoped = false

        func flush() {
            if let resolver = current { resolvers.append(resolver) }
            current = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("DNS configuration") {
                flush()
                scoped = line.contains("scoped")
                continue
            }
            if line.hasPrefix("resolver #") {
                flush()
                let number = Int(line.dropFirst("resolver #".count).trimmingCharacters(in: .whitespaces)) ?? (resolvers.count + 1)
                current = Resolver(isScoped: scoped, number: number)
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            if key.hasPrefix("nameserver[") {
                if !value.isEmpty { current?.nameservers.append(value) }
            } else if key.hasPrefix("search domain[") {
                if !value.isEmpty { current?.searchDomains.append(value) }
            } else if key == "domain" {
                current?.domain = value.isEmpty ? nil : value
            } else if key == "if_index" {
                // 形如 `14 (en0)`
                let parts = value.split(separator: " ", maxSplits: 1)
                current?.ifIndex = parts.first.flatMap { Int($0) }
                if parts.count > 1 {
                    let name = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "() "))
                    current?.interfaceName = name.isEmpty ? nil : name
                }
            } else if key == "flags" {
                current?.flags = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if key == "order" {
                current?.order = Int(value)
            }
        }
        flush()
        return resolvers
    }
}
