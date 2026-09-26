import Foundation

/// `scutil` 的 `show` 输出中的值：字符串、数组或字典。
public indirect enum ScutilValue: Sendable, Equatable {
    case string(String)
    case array([ScutilValue])
    case dictionary([String: ScutilValue])

    public subscript(key: String) -> ScutilValue? {
        if case .dictionary(let dict) = self { return dict[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var arrayValue: [ScutilValue]? {
        if case .array(let list) = self { return list }
        return nil
    }

    public var dictionaryValue: [String: ScutilValue]? {
        if case .dictionary(let dict) = self { return dict }
        return nil
    }

    /// 数组中的字符串元素（非字符串元素忽略）。
    public var stringArray: [String]? {
        arrayValue?.compactMap { $0.stringValue }
    }

    /// 取字典中 `ServerAddresses` 并规范化（`[""]` 视为空）。
    public var serverAddresses: [String] {
        DNSList.normalize(self["ServerAddresses"]?.stringArray ?? [])
    }
}

/// 解析错误。
public enum ScutilDictionaryParseError: Error, Equatable, Sendable {
    case empty
    case unexpectedLine(String)
    case unterminated
}

/// 解析 `scutil` 的 `show` 输出为嵌套字典和数组。
///
/// 输入示例：
/// ```
/// <dictionary> {
///   ServerAddresses : <array> {
///     0 : 119.29.29.29
///   }
/// }
/// ```
public enum ScutilDictionaryParser {
    /// 解析单个值（首个 `<dictionary>` 或 `<array>`）。
    public static func parse(_ text: String) throws -> ScutilValue {
        let values = try parseSequence(text)
        guard let first = values.first else { throw ScutilDictionaryParseError.empty }
        return first
    }

    /// 依次解析文本中的全部顶层值。顶层不属于结构的行（如 `PrimaryService=<id>`、`== key` 标题）被跳过。
    public static func parseSequence(_ text: String) throws -> [ScutilValue] {
        let lines = text.components(separatedBy: .newlines)
        var index = 0
        var values: [ScutilValue] = []
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if let opener = containerKind(line) {
                index += 1
                values.append(try parseContainer(opener, lines: lines, index: &index))
            } else {
                index += 1
            }
        }
        return values
    }

    private enum ContainerKind {
        case dictionary
        case array
    }

    private static func containerKind(_ text: String) -> ContainerKind? {
        if text.hasPrefix("<dictionary>") && text.hasSuffix("{") { return .dictionary }
        if text.hasPrefix("<array>") && text.hasSuffix("{") { return .array }
        return nil
    }

    private static func parseContainer(_ kind: ContainerKind, lines: [String], index: inout Int) throws -> ScutilValue {
        var dict: [String: ScutilValue] = [:]
        var items: [(Int, ScutilValue)] = []

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if line.isEmpty { continue }
            if line == "}" {
                switch kind {
                case .dictionary:
                    return .dictionary(dict)
                case .array:
                    return .array(items.sorted { $0.0 < $1.0 }.map { $0.1 })
                }
            }
            guard let (key, rawValue) = splitEntry(line) else {
                throw ScutilDictionaryParseError.unexpectedLine(line)
            }
            let value: ScutilValue
            if let nested = containerKind(rawValue) {
                value = try parseContainer(nested, lines: lines, index: &index)
            } else {
                value = .string(rawValue)
            }
            switch kind {
            case .dictionary:
                dict[key] = value
            case .array:
                items.append((Int(key) ?? items.count, value))
            }
        }
        throw ScutilDictionaryParseError.unterminated
    }

    /// 拆分 `key : value`。值可以为空（例如 `0 : `），也可以含冒号。
    private static func splitEntry(_ line: String) -> (String, String)? {
        if let range = line.range(of: " : ") {
            let key = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : (key, value)
        }
        if line.hasSuffix(" :") {
            let key = line.dropLast(2).trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : (key, "")
        }
        return nil
    }
}
