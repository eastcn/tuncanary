import Foundation
import TunCanaryCore
import TunCanarySystem

/// MagicDNS 反查：PTR 报文解析与结果映射。不访问网络。
enum MagicDNSTests {
    /// 问题 2.1.80.100.in-addr.arpa PTR；回答为 PTR，数据 “laptop” + 指针 → 问题名之后的 “example-tailnet.ts.net”
    /// 不在报文中，所以直接写完整名字，再用一条压缩指针指回数据中的名字测试展开。
    static let ptrResponse: [UInt8] = {
        var bytes: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        // 偏移 12：问题名
        bytes += DNSMessageTests.name(["2", "1", "80", "100", "in-addr", "arpa"])
        bytes += [0x00, 0x0C, 0x00, 0x01]
        // 回答：名字指针 → 12，类型 PTR，TTL 600
        let data = DNSMessageTests.label("laptop") + DNSMessageTests.name(["example-tailnet", "ts", "net"])
        bytes += [0xC0, 0x0C, 0x00, 0x0C, 0x00, 0x01, 0x00, 0x00, 0x02, 0x58, 0x00, UInt8(data.count)]
        bytes += data
        return bytes
    }()

    static var suite: TestSuite {
        TestSuite("System.MagicDNS", [
            TestCase("反查名与 PTR 应答解析") { t in
                t.expectEqual(DNSMessage.reverseName(IPv4("100.80.1.2")!), "2.1.80.100.in-addr.arpa")
                let response = try DNSMessage.parseResponse(ptrResponse)
                t.expectEqual(response.ptrAnswer, "laptop.example-tailnet.ts.net")
                t.expectEqual(response.ipv4Answers, [])
                let query = try DNSMessage.encodeQuery(id: 7, name: "2.1.80.100.in-addr.arpa", type: DNSMessage.typePTR)
                t.expectEqual(Array(query.suffix(4)), [0x00, 0x0C, 0x00, 0x01])
            },
            TestCase("结果映射：NXDOMAIN 为无名称，其余错误为失败") { t in
                let response = try DNSMessage.parseResponse(ptrResponse)
                t.expectEqual(MagicDNSProber.result(.answered(latency: 0.01, response: response)),
                              .answered(name: "laptop.example-tailnet.ts.net"))
                var nxdomain = response
                nxdomain.responseCode = 3
                nxdomain.answers = []
                t.expectEqual(MagicDNSProber.result(.answered(latency: 0.01, response: nxdomain)), .answered(name: nil))
                var servfail = nxdomain
                servfail.responseCode = 2
                t.expectEqual(MagicDNSProber.result(.answered(latency: 0.01, response: servfail)),
                              .failed(reason: "应答码 2"))
                t.expectEqual(MagicDNSProber.result(.timedOut), .timedOut)
                t.expectEqual(MagicDNSProber.result(.refused), .failed(reason: "端口拒绝"))
            },
        ])
    }
}
