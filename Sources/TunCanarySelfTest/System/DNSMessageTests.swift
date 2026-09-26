import Foundation
import TunCanaryCore
import TunCanarySystem

/// DNS 报文编解码与 UDP 客户端测试（只用本机回环，不访问外部网络）。
enum DNSMessageTests {
    /// 带 CNAME 与多级压缩指针的应答：
    /// 问题 www.google.com；回答 1 为 CNAME（名字指针 → 12，数据 “edge” + 指针 → google.com）；
    /// 回答 2 为 A 记录（名字指针 → CNAME 数据中的 edge.google.com），地址 198.18.0.26。
    static let compressedResponse: [UInt8] = {
        var bytes: [UInt8] = [0xBE, 0xEF, 0x81, 0x80, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00]
        // 偏移 12：www.google.com
        bytes += name(["www", "google", "com"])
        bytes += [0x00, 0x01, 0x00, 0x01]
        // 偏移 32：CNAME，数据从偏移 44 开始
        bytes += [0xC0, 0x0C, 0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x07]
        bytes += label("edge")
        bytes += [0xC0, 0x10]
        // 偏移 51：A 记录，名字指向偏移 44
        bytes += [0xC0, 0x2C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04]
        bytes += [198, 18, 0, 26]
        return bytes
    }()

    /// 单个标签：长度字节 + ASCII。
    static func label(_ text: String) -> [UInt8] {
        let utf8: [UInt8] = Array(text.utf8)
        return [UInt8(utf8.count)] + utf8
    }

    /// 完整名字：各标签 + 结尾 0。
    static func name(_ labels: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        for item in labels { bytes += label(item) }
        bytes.append(0)
        return bytes
    }

    static var suite: TestSuite {
        TestSuite("System.DNSMessage", [
            TestCase("编码 A 查询") { t in
                let bytes = try DNSMessage.encodeQuery(id: 0x1234, name: "www.google.com")
                var expected: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
                expected += name(["www", "google", "com"])
                expected += [0x00, 0x01, 0x00, 0x01]
                t.expectEqual(bytes, expected)
                t.expectEqual(try DNSMessage.encodeQuery(id: 0x1234, name: "www.google.com."), expected, "末尾的点")
            },
            TestCase("非法查询名") { t in
                t.expectThrows(try DNSMessage.encodeName(""))
                t.expectThrows(try DNSMessage.encodeName("a..b"))
                t.expectThrows(try DNSMessage.encodeName(String(repeating: "a", count: 64) + ".com"))
                t.expectThrows(try DNSMessage.encodeName(Array(repeating: String(repeating: "a", count: 60), count: 5).joined(separator: ".")))
                t.expectThrows(try DNSMessage.encodeName("中文.com"))
                t.expectThrows(try DNSMessage.encodeName("a b.com"))
            },
            TestCase("查询报文可被解析回来") { t in
                let bytes = try DNSMessage.encodeQuery(id: 7, name: "example.com")
                let parsed = try DNSMessage.parseResponse(bytes)
                t.expectEqual(parsed.id, 7)
                t.expect(!parsed.isResponse)
                t.expectEqual(parsed.questions, [DNSQuestion(name: "example.com", type: 1, klass: 1)])
                t.expectEqual(parsed.answers, [])
            },
            TestCase("压缩指针与 CNAME") { t in
                let response = try DNSMessage.parseResponse(compressedResponse)
                t.expectEqual(response.id, 0xBEEF)
                t.expect(response.isResponse)
                t.expect(!response.isTruncated)
                t.expectEqual(response.responseCode, 0)
                t.expectEqual(response.questions.first?.name, "www.google.com")
                t.expectEqual(response.answers.count, 2)
                t.expectEqual(response.answers.first?.name, "www.google.com")
                t.expectEqual(response.answers.first?.type, DNSMessage.typeCNAME)
                t.expectEqual(response.answers.last?.name, "edge.google.com")
                t.expectEqual(response.answers.last?.ttl, 60)
                t.expectEqual(response.ipv4Answers, [IPv4("198.18.0.26")!])
                // CNAME 数据本身也是带指针的名字。
                var offset = 44
                t.expectEqual(try DNSMessage.readName(compressedResponse, &offset), "edge.google.com")
                t.expectEqual(offset, 51, "遇到指针后偏移移到指针之后")
            },
            TestCase("任意位置截断都报 truncated") { t in
                for length in 0..<compressedResponse.count {
                    let prefix = Array(compressedResponse.prefix(length))
                    do {
                        _ = try DNSMessage.parseResponse(prefix)
                        t.fail("长度 \(length) 的截断报文不应解析成功")
                    } catch let error as DNSMessageError {
                        t.expectEqual(error, .truncated, "长度 \(length)")
                    }
                }
            },
            TestCase("指针成环、越界与不支持的标签") { t in
                let header: [UInt8] = [0, 1, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0]
                t.expectThrowsDNS(try DNSMessage.parseResponse(header + [0xC0, 0x0C, 0, 1, 0, 1]), .pointerLoop)
                t.expectThrowsDNS(try DNSMessage.parseResponse(header + [0xC0, 0xFF, 0, 1, 0, 1]), .badPointer)
                t.expectThrowsDNS(try DNSMessage.parseResponse(header + [0x40, 0, 0, 1, 0, 1]), .unsupportedLabel)
                // 两个指针互指
                let mutual = header + [0xC0, 0x0E, 0xC0, 0x0C, 0, 1, 0, 1]
                t.expectThrowsDNS(try DNSMessage.parseResponse(mutual), .pointerLoop)
            },
            TestCase("非 A 记录和长度不符的数据被忽略") { t in
                var bytes: [UInt8] = [0, 9, 0x81, 0x83, 0, 0, 0, 2, 0, 0, 0, 0]
                // AAAA 记录（16 字节）
                bytes += name(["a"])
                bytes += [0x00, 0x1C, 0x00, 0x01, 0, 0, 0, 1, 0x00, 0x10]
                bytes += [UInt8](repeating: 0, count: 16)
                // A 类型但数据只有 3 字节
                bytes += name(["b"])
                bytes += [0x00, 0x01, 0x00, 0x01, 0, 0, 0, 1, 0x00, 0x03]
                bytes += [1, 2, 3]
                let response = try DNSMessage.parseResponse(bytes)
                t.expectEqual(response.answers.count, 2)
                t.expectEqual(response.ipv4Answers, [])
                t.expectEqual(response.responseCode, 3, "NXDOMAIN")
            },
        ])
    }

    static var clientSuite: TestSuite {
        TestSuite("System.UDPDNSClient", [
            TestCase("丢弃错误 ID 与非应答报文，返回匹配的应答", timeout: 10) { t in
                let server = try SystemTestUDPServer()
                defer { server.close() }
                let answer = IPv4("198.18.0.26")!
                server.serveOnce { query in
                    [
                        SystemTestKit.makeAResponse(to: query, answers: [IPv4("1.2.3.4")!], id: 0xFFFF),
                        SystemTestKit.makeAResponse(to: query, answers: [IPv4("5.6.7.8")!], isResponse: false),
                        [0x00, 0x01, 0x02],
                        SystemTestKit.makeAResponse(to: query, answers: [answer]),
                    ]
                }
                let outcome = UDPDNSClient.query(host: "127.0.0.1", port: server.port, name: "www.google.com",
                                                 timeout: 2, id: 0x4242)
                guard case .answered(let latency, let response) = outcome else {
                    t.fail("应收到应答：\(outcome)")
                    return
                }
                t.expectEqual(response.id, 0x4242)
                t.expectEqual(response.ipv4Answers, [answer])
                t.expect(latency >= 0 && latency < 1, "延迟 \(latency)")
            },
            TestCase("MihomoDNSProber 返回 success", timeout: 10) { t in
                let server = try SystemTestUDPServer()
                defer { server.close() }
                server.serveOnce { query in [SystemTestKit.makeAResponse(to: query, answers: [IPv4("198.18.0.7")!])] }
                let result = await MihomoDNSProber(timeout: 2).probe(port: server.port)
                guard case .success(let port, _, let answers) = result else {
                    t.fail("应为 success：\(result)")
                    return
                }
                t.expectEqual(port, server.port)
                t.expectEqual(answers, [IPv4("198.18.0.7")!])
            },
            TestCase("无应答时按超时返回", timeout: 10) { t in
                let server = try SystemTestUDPServer()
                defer { server.close() }
                server.serveOnce { _ in [] }
                let start = Date()
                let outcome = UDPDNSClient.query(host: "127.0.0.1", port: server.port, name: "www.google.com", timeout: 0.3)
                let elapsed = Date().timeIntervalSince(start)
                t.expectEqual(outcome, .timedOut)
                t.expect(elapsed >= 0.25 && elapsed < 1.5, "耗时 \(elapsed)")
                t.expectEqual(MihomoDNSProber.result(port: 1, outcome: outcome), .noResponse(port: 1))
            },
            TestCase("端口未监听时立即返回拒绝", timeout: 10) { t in
                // 临时端口关闭后可能被并发用例的 UDP 服务重新绑定，此时换一个端口重试。
                var port = 0
                var outcome = DNSQueryOutcome.timedOut
                var elapsed: TimeInterval = 0
                for _ in 0..<3 {
                    port = try SystemTestUDPServer.closedPort()
                    let start = Date()
                    outcome = UDPDNSClient.query(host: "127.0.0.1", port: port, name: "www.google.com", timeout: 2)
                    elapsed = Date().timeIntervalSince(start)
                    if outcome == .refused { break }
                }
                t.expectEqual(outcome, .refused)
                t.expect(elapsed < 1, "耗时 \(elapsed)")
                t.expectEqual(MihomoDNSProber.result(port: port, outcome: outcome), .noResponse(port: port))
            },
            TestCase("参数无效") { t in
                if case .failed = UDPDNSClient.query(host: "127.0.0.1", port: 0, name: "a.com", timeout: 1) {} else {
                    t.fail("端口 0 应失败")
                }
                if case .failed = UDPDNSClient.query(host: "not-an-ip", port: 53, name: "a.com", timeout: 1) {} else {
                    t.fail("地址无效应失败")
                }
                if case .failed = UDPDNSClient.query(host: "127.0.0.1", port: 53, name: "a..com", timeout: 1) {} else {
                    t.fail("查询名无效应失败")
                }
            },
        ])
    }
}

private extension TestContext {
    func expectThrowsDNS<T>(_ expression: @autoclosure () throws -> T, _ expected: DNSMessageError,
                            file: StaticString = #filePath, line: UInt = #line) {
        do {
            let value = try expression()
            fail("期望抛出 \(expected)，实际返回 \(value)", file: file, line: line)
        } catch let error as DNSMessageError {
            if error != expected { fail("期望 \(expected)，实际 \(error)", file: file, line: line) }
        } catch {
            fail("期望 \(expected)，实际 \(error)", file: file, line: line)
        }
    }
}
