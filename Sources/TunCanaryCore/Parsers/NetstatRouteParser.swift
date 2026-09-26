import Foundation

/// 解析 `netstat -rn -f inet` 输出。只读 `Internet:` 段，遇到 `Internet6:` 停止。
public enum NetstatRouteParser {
    public static func parse(_ text: String) -> [RouteEntry] {
        var routes: [RouteEntry] = []
        var inInternet = false
        var sawSectionHeader = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "Routing tables" { continue }
            if line.hasPrefix("Internet6") {
                inInternet = false
                sawSectionHeader = true
                continue
            }
            if line.hasPrefix("Internet") {
                inInternet = true
                sawSectionHeader = true
                continue
            }
            // 没有段标题时（只截取了表体）也按 IPv4 表处理。
            if sawSectionHeader && !inInternet { continue }
            if line.hasPrefix("Destination") { continue }

            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 4 else { continue }
            routes.append(RouteEntry(
                destination: fields[0],
                gateway: fields[1],
                flags: fields[2],
                interfaceName: fields[3]
            ))
        }
        return routes
    }
}
