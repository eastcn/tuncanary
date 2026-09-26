import Foundation
import TunCanaryCore

/// DNS 报文错误。
public enum DNSMessageError: Error, Equatable, Sendable {
    /// 查询名不合法（空标签、标签超过 63 字节、总长超过 255 字节、含非 ASCII 字符）。
    case invalidName(String)
    /// 报文在字段中途结束。
    case truncated
    /// 压缩指针指向报文之外。
    case badPointer
    /// 压缩指针跳转过多（成环）。
    case pointerLoop
    /// 不支持的标签类型（高两位为 01 或 10）。
    case unsupportedLabel
    /// 解码后的名字超过 255 字节。
    case nameTooLong
}

/// 问题段条目。
public struct DNSQuestion: Sendable, Equatable {
    public var name: String
    public var type: UInt16
    public var klass: UInt16

    public init(name: String, type: UInt16, klass: UInt16) {
        self.name = name
        self.type = type
        self.klass = klass
    }
}

/// 资源记录。
public struct DNSRecord: Sendable, Equatable {
    public var name: String
    public var type: UInt16
    public var klass: UInt16
    public var ttl: UInt32
    public var data: [UInt8]

    public init(name: String, type: UInt16, klass: UInt16, ttl: UInt32, data: [UInt8]) {
        self.name = name
        self.type = type
        self.klass = klass
        self.ttl = ttl
        self.data = data
    }

    /// A 记录（IN 类、4 字节数据）的地址；其他记录为 nil。
    public var ipv4: IPv4? {
        guard type == DNSMessage.typeA, klass == DNSMessage.classIN, data.count == 4 else { return nil }
        return IPv4(data[0], data[1], data[2], data[3])
    }
}

/// 解析后的应答报文。只解析头部、问题段和回答段，权威段与附加段忽略。
public struct DNSResponse: Sendable, Equatable {
    public var id: UInt16
    /// QR 位。
    public var isResponse: Bool
    /// TC 位（UDP 应答被截断）。
    public var isTruncated: Bool
    /// RCODE，0 为 NOERROR。
    public var responseCode: UInt8
    public var questions: [DNSQuestion]
    public var answers: [DNSRecord]

    /// 回答段中的 A 记录地址（按出现顺序，CNAME 等其他记录跳过）。
    public var ipv4Answers: [IPv4] {
        answers.compactMap(\.ipv4)
    }
}

/// 手写的最小 DNS 报文编解码：只编码单个问题的查询，只解析 A 记录应答，支持压缩指针。
public enum DNSMessage {
    public static let typeA: UInt16 = 1
    public static let typeCNAME: UInt16 = 5
    public static let classIN: UInt16 = 1
    static let headerLength = 12
    static let maxPointerJumps = 64

    // MARK: 编码

    /// 编码查询报文。`recursionDesired` 对应 RD 位。
    public static func encodeQuery(id: UInt16, name: String, type: UInt16 = typeA, recursionDesired: Bool = true) throws -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(headerLength + name.utf8.count + 6)
        append16(&bytes, id)
        append16(&bytes, recursionDesired ? 0x0100 : 0x0000)
        append16(&bytes, 1) // QDCOUNT
        append16(&bytes, 0) // ANCOUNT
        append16(&bytes, 0) // NSCOUNT
        append16(&bytes, 0) // ARCOUNT
        bytes += try encodeName(name)
        append16(&bytes, type)
        append16(&bytes, classIN)
        return bytes
    }

    /// 编码域名为标签序列（允许末尾一个点）。
    public static func encodeName(_ name: String) throws -> [UInt8] {
        var text = name
        if text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty else { throw DNSMessageError.invalidName(name) }
        var bytes: [UInt8] = []
        for label in text.split(separator: ".", omittingEmptySubsequences: false) {
            let utf8 = Array(label.utf8)
            guard !utf8.isEmpty, utf8.count <= 63, utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
                throw DNSMessageError.invalidName(name)
            }
            bytes.append(UInt8(utf8.count))
            bytes += utf8
        }
        bytes.append(0)
        guard bytes.count <= 255 else { throw DNSMessageError.invalidName(name) }
        return bytes
    }

    // MARK: 解码

    /// 解析应答报文。任何字段在中途结束都抛出 `.truncated`。
    public static func parseResponse(_ bytes: [UInt8]) throws -> DNSResponse {
        var offset = 0
        let id = try read16(bytes, &offset)
        let flags = try read16(bytes, &offset)
        let questionCount = try read16(bytes, &offset)
        let answerCount = try read16(bytes, &offset)
        _ = try read16(bytes, &offset) // NSCOUNT
        _ = try read16(bytes, &offset) // ARCOUNT

        var questions: [DNSQuestion] = []
        for _ in 0..<questionCount {
            let name = try readName(bytes, &offset)
            let type = try read16(bytes, &offset)
            let klass = try read16(bytes, &offset)
            questions.append(DNSQuestion(name: name, type: type, klass: klass))
        }

        var answers: [DNSRecord] = []
        for _ in 0..<answerCount {
            let name = try readName(bytes, &offset)
            let type = try read16(bytes, &offset)
            let klass = try read16(bytes, &offset)
            let ttl = try read32(bytes, &offset)
            let length = Int(try read16(bytes, &offset))
            guard offset + length <= bytes.count else { throw DNSMessageError.truncated }
            let data = Array(bytes[offset..<(offset + length)])
            offset += length
            answers.append(DNSRecord(name: name, type: type, klass: klass, ttl: ttl, data: data))
        }

        return DNSResponse(
            id: id,
            isResponse: flags & 0x8000 != 0,
            isTruncated: flags & 0x0200 != 0,
            responseCode: UInt8(flags & 0x000f),
            questions: questions,
            answers: answers
        )
    }

    /// 读取域名（支持压缩指针）。`offset` 移到名字之后（遇到指针时移到指针之后）。
    public static func readName(_ bytes: [UInt8], _ offset: inout Int) throws -> String {
        var labels: [String] = []
        var position = offset
        var jumped = false
        var jumps = 0
        var encodedLength = 1

        while true {
            guard position < bytes.count else { throw DNSMessageError.truncated }
            let length = bytes[position]
            switch length & 0xC0 {
            case 0x00:
                if length == 0 {
                    if !jumped { offset = position + 1 }
                    return labels.joined(separator: ".")
                }
                let start = position + 1
                let end = start + Int(length)
                guard end <= bytes.count else { throw DNSMessageError.truncated }
                encodedLength += Int(length) + 1
                guard encodedLength <= 255 else { throw DNSMessageError.nameTooLong }
                labels.append(String(decoding: bytes[start..<end], as: UTF8.self))
                position = end
            case 0xC0:
                guard position + 1 < bytes.count else { throw DNSMessageError.truncated }
                let target = Int(length & 0x3F) << 8 | Int(bytes[position + 1])
                guard target < bytes.count else { throw DNSMessageError.badPointer }
                jumps += 1
                guard jumps <= maxPointerJumps else { throw DNSMessageError.pointerLoop }
                if !jumped {
                    offset = position + 2
                    jumped = true
                }
                position = target
            default:
                throw DNSMessageError.unsupportedLabel
            }
        }
    }

    // MARK: 字节工具

    static func append16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xff))
    }

    static func read16(_ bytes: [UInt8], _ offset: inout Int) throws -> UInt16 {
        guard offset + 2 <= bytes.count else { throw DNSMessageError.truncated }
        let value = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        offset += 2
        return value
    }

    static func read32(_ bytes: [UInt8], _ offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw DNSMessageError.truncated }
        var value: UInt32 = 0
        for index in 0..<4 { value = value << 8 | UInt32(bytes[offset + index]) }
        offset += 4
        return value
    }
}
