import Foundation

/// DNS 地址列表的规范化与比较。
public enum DNSList {
    /// 去掉首尾空白、空字符串和重复项，保持原顺序。`[""]` 规范化后为空列表。
    public static func normalize<S: Sequence>(_ list: S) -> [String] where S.Element == String {
        var seen = Set<String>()
        var result: [String] = []
        for item in list {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    /// 拆分逗号（含中文逗号、顿号）或空白分隔的地址串，例如 `"10.0.0.1, 10.0.0.2"`。
    public static func split(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，、;；").union(.whitespacesAndNewlines)
        return normalize(text.components(separatedBy: separators))
    }

    /// 忽略顺序比较两个列表（先规范化）。
    public static func sameSet(_ lhs: [String], _ rhs: [String]) -> Bool {
        Set(normalize(lhs)) == Set(normalize(rhs))
    }

    /// 展示用文本：空列表显示“空”。
    public static func display(_ list: [String]) -> String {
        let normalized = normalize(list)
        return normalized.isEmpty ? "空" : normalized.joined(separator: ", ")
    }
}
