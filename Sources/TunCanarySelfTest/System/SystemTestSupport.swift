import Darwin
import Foundation
import TunCanaryCore
import TunCanarySystem

/// System 测试共用的辅助工具（命名空间避免与其他模块测试冲突）。
enum SystemTestKit {
    /// 新建临时目录。
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuncanary-system-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 删除临时目录（先恢复权限，避免 chmod 000 的文件删不掉）。
    static func removeDirectory(_ url: URL) {
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            for case let relative as String in enumerator {
                chmod(url.appendingPathComponent(relative).path, 0o700)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// 在临时 home 下写入合成的 Clash Verge 配置（不读取本机真实配置）。
    static func writeClashConfig(home: URL, verge: String?, clash: String?) throws {
        let paths = KnownPaths(homeDirectory: home.path)
        try FileManager.default.createDirectory(atPath: paths.clashVergeConfigDirectory, withIntermediateDirectories: true)
        if let verge {
            try verge.write(toFile: paths.vergeConfigFile, atomically: true, encoding: .utf8)
        }
        if let clash {
            try clash.write(toFile: paths.clashVergeConfigFile, atomically: true, encoding: .utf8)
        }
    }

    /// 合成的 clash-verge.yaml：DNS 端口可指定，混入不应读取的 secret。
    static func clashYAML(port: Int, tunEnable: Bool = true) -> String {
        FixtureLoader.clashVergeYAML(tunEnable: tunEnable)
            .replacingOccurrences(of: "listen: 0.0.0.0:7874", with: "listen: 0.0.0.0:\(port)")
    }

    /// 构造 A 记录应答：复制查询的 ID 与问题段，回答用压缩指针指向问题名。
    static func makeAResponse(to query: [UInt8], answers: [IPv4], id: UInt16? = nil, isResponse: Bool = true) -> [UInt8] {
        guard query.count >= 12 else { return [] }
        var bytes: [UInt8] = []
        if let id {
            bytes += [UInt8(id >> 8), UInt8(id & 0xff)]
        } else {
            bytes += query[0..<2]
        }
        bytes += isResponse ? [0x81, 0x80] : [0x01, 0x00]
        bytes += [0x00, 0x01, 0x00, UInt8(answers.count), 0x00, 0x00, 0x00, 0x00]
        bytes += query[12...]
        for ip in answers {
            bytes += [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04]
            bytes += ip.octets
        }
        return bytes
    }

    /// 线程安全的收集器。
    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) {
            storage = value
        }

        var value: Value {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func mutate(_ body: (inout Value) -> Void) {
            lock.lock()
            body(&storage)
            lock.unlock()
        }
    }

    static func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// 本机回环上的最小 UDP 服务，用于测试 DNS 客户端（不访问外部网络）。
final class SystemTestUDPServer: @unchecked Sendable {
    let fd: Int32
    let port: Int

    init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SystemCollectionError("socket 失败") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw SystemCollectionError("bind 失败")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.fd = fd
        self.port = Int(UInt16(bigEndian: address.sin_port))
    }

    /// 取一个当前未监听的端口（绑定后立即关闭）。
    static func closedPort() throws -> Int {
        let server = try SystemTestUDPServer()
        let port = server.port
        server.close()
        return port
    }

    /// 后台接收一个查询，按 `respond` 依次发回若干报文（可模拟错误 ID）。最多等 `wait` 秒。
    func serveOnce(wait: TimeInterval = 3, _ respond: @escaping @Sendable ([UInt8]) -> [[UInt8]]) {
        let fd = self.fd
        DispatchQueue.global().async {
            var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&entry, 1, Int32(wait * 1000)) > 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 2048)
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &peer) { peerPointer in
                peerPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    buffer.withUnsafeMutableBytes { recvfrom(fd, $0.baseAddress, $0.count, 0, sockaddrPointer, &peerLength) }
                }
            }
            guard count > 0 else { return }
            for reply in respond(Array(buffer[0..<count])) {
                _ = withUnsafePointer(to: &peer) { peerPointer in
                    peerPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        reply.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, sockaddrPointer, peerLength) }
                    }
                }
            }
        }
    }

    func close() {
        Darwin.close(fd)
    }
}
