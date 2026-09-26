import Foundation

/// 解析 `ifconfig` 输出（名称、UP 标志、IPv4），供 fixture 与备用路径使用。
public enum IfconfigParser {
    public static func parse(_ text: String) -> [InterfaceInfo] {
        var interfaces: [InterfaceInfo] = []
        var current: InterfaceInfo?

        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let isHeader = !(rawLine.first == " " || rawLine.first == "\t")

            if isHeader {
                // 形如 `utun1024: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500`
                guard let colon = rawLine.firstIndex(of: ":") else { continue }
                if let interface = current { interfaces.append(interface) }
                let name = String(rawLine[..<colon])
                var flags: [String] = []
                if let open = rawLine.firstIndex(of: "<"), let close = rawLine.firstIndex(of: ">"), open < close {
                    flags = rawLine[rawLine.index(after: open)..<close]
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
                current = InterfaceInfo(name: name, isUp: flags.contains("UP"), flags: flags)
                continue
            }

            let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "inet", current != nil else { continue }
            if let ip = IPv4(String(fields[1])) {
                current?.ipv4Addresses.append(ip)
            }
        }
        if let interface = current { interfaces.append(interface) }
        return interfaces
    }
}
