import Darwin
import Foundation
import TunCanaryCore

/// 通过 unix socket 访问 mihomo 控制接口（只读）。
///
/// Clash Verge Rev 由系统服务以 root 身份启动 `verge-mihomo`，控制接口是命令行参数 `-ext-ctl-unix` 指定的 socket，
/// 文件归当前用户所有、权限 600，不需要 secret。配置文件中写的 socket 路径可能与实际不符，所以从进程参数中读取。
public struct MihomoController: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: 定位

    /// 找到当前用户可访问的控制 socket；找不到时返回原因。
    public static func locate() -> Result<MihomoController, MihomoControllerError> {
        var candidates: [String] = []
        if let pids = try? ProcessScanner.listPIDs() {
            for pid in pids where ProcessScanner.executablePath(of: pid).map({
                ($0 as NSString).lastPathComponent == KnownPaths.mihomoProcessName
            }) == true {
                if let arguments = arguments(of: pid), let path = socketArgument(arguments) {
                    candidates.append(path)
                }
            }
        }
        candidates.append("/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock")
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return .success(MihomoController(socketPath: path))
        }
        return .failure(.notFound)
    }

    /// 从命令行参数中取 `-ext-ctl-unix` 的值（也接受 `--ext-ctl-unix` 和 `=` 写法）。
    public static func socketArgument(_ arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            let name = argument.hasPrefix("--") ? String(argument.dropFirst()) : argument
            if name == "-ext-ctl-unix", index + 1 < arguments.count { return arguments[index + 1] }
            if name.hasPrefix("-ext-ctl-unix=") { return String(name.dropFirst("-ext-ctl-unix=".count)) }
        }
        return nil
    }

    /// 读取进程的命令行参数（`KERN_PROCARGS2`）。不含可执行文件路径。
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var offset = MemoryLayout<Int32>.size
        // 跳过可执行文件路径及其后的填充 0。
        while offset < size, buffer[offset] != 0 { offset += 1 }
        while offset < size, buffer[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        while offset < size, arguments.count < argc {
            let start = offset
            while offset < size, buffer[offset] != 0 { offset += 1 }
            arguments.append(String(decoding: buffer[start..<offset], as: UTF8.self))
            offset += 1
        }
        return Array(arguments.dropFirst())
    }

    // MARK: 请求

    /// 测一个节点的延迟：`GET /proxies/<名称>/delay`。
    public func delay(node: String, url: String = "https://www.gstatic.com/generate_204",
                      timeout: TimeInterval) -> NodeDelay {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]")
        guard let name = node.addingPercentEncoding(withAllowedCharacters: allowed),
              let target = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return .failed(reason: "节点名无法编码")
        }
        let milliseconds = Int(timeout * 1000)
        let path = "/proxies/\(name)/delay?timeout=\(milliseconds)&url=\(target)"
        switch UnixHTTPClient.get(socketPath: socketPath, path: path, timeout: timeout + 1) {
        case .success(let response):
            let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            if response.status == 200, let delay = object?["delay"] as? Int { return .milliseconds(delay) }
            if let message = object?["message"] as? String {
                return .failed(reason: message.lowercased().contains("timeout") ? "超时" : message)
            }
            return .failed(reason: "HTTP \(response.status)")
        case .failure(let error):
            return .failed(reason: error.message)
        }
    }

    /// 订阅 `/logs?level=info`，把收到的连接记录交给 `handler`，直到 `shouldStop` 返回 true 或超过 `timeout`。
    public func streamConnections(timeout: TimeInterval, shouldStop: @escaping @Sendable () -> Bool,
                                  handler: @escaping @Sendable (ProxyLogConnection) -> Void) -> MihomoControllerError? {
        UnixHTTPClient.stream(socketPath: socketPath, path: "/logs?level=info", timeout: timeout,
                              shouldStop: shouldStop) { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? String,
                  let connection = ProxyLogConnection.parse(payload) else { return }
            handler(connection)
        }
    }
}

/// 控制接口访问错误。
public enum MihomoControllerError: Error, Equatable, Sendable {
    case notFound
    case connectFailed(String)
    case timedOut
    case badResponse

    public var message: String {
        switch self {
        case .notFound: return "未找到 Clash Verge Rev 的控制接口"
        case .connectFailed(let reason): return "无法连接控制接口（\(reason)）"
        case .timedOut: return "控制接口无响应"
        case .badResponse: return "控制接口应答无法解析"
        }
    }
}

/// 经 unix socket 发送 HTTP/1.1 GET 的最小客户端（阻塞调用）。
enum UnixHTTPClient {
    struct Response {
        var status: Int
        var body: Data
    }

    static func get(socketPath: String, path: String, timeout: TimeInterval) -> Result<Response, MihomoControllerError> {
        let fd: Int32
        switch connect(socketPath, path: path) {
        case .success(let value): fd = value
        case .failure(let error): return .failure(error)
        }
        defer { close(fd) }
        var received = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch read(fd, deadline: deadline) {
            case .data(let chunk): received.append(chunk)
            case .closed: return parse(received).map { .success($0) } ?? .failure(.badResponse)
            case .timedOut: return .failure(.timedOut)
            case .failed(let reason): return .failure(.connectFailed(reason))
            }
        }
    }

    /// 读取分块传输的流式应答，按行交给 `line`。
    static func stream(socketPath: String, path: String, timeout: TimeInterval,
                       shouldStop: @Sendable () -> Bool, line: (String) -> Void) -> MihomoControllerError? {
        let fd: Int32
        switch connect(socketPath, path: path) {
        case .success(let value): fd = value
        case .failure(let error): return error
        }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var headerParsed = false
        var decoder = ChunkedDecoder()
        var pending = ""
        while !shouldStop() {
            // 每次最多等 0.1 秒，以便及时响应 shouldStop。
            let slice = min(deadline, Date().addingTimeInterval(0.1))
            switch read(fd, deadline: slice) {
            case .data(let chunk):
                buffer.append(chunk)
                if !headerParsed {
                    guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { continue }
                    let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    guard header.hasPrefix("HTTP/1.1 200") else { return .badResponse }
                    headerParsed = true
                    buffer = Data(buffer[end.upperBound...])
                }
                pending += String(decoding: decoder.feed(buffer), as: UTF8.self)
                buffer.removeAll()
                while let newline = pending.firstIndex(of: "\n") {
                    let text = String(pending[..<newline]).trimmingCharacters(in: .whitespaces)
                    pending = String(pending[pending.index(after: newline)...])
                    if !text.isEmpty { line(text) }
                }
            case .timedOut:
                if Date() >= deadline { return nil }
            case .closed:
                return nil
            case .failed(let reason):
                return .connectFailed(reason)
            }
        }
        return nil
    }

    private enum ReadResult {
        case data(Data)
        case closed
        case timedOut
        case failed(String)
    }

    private static func connect(_ socketPath: String, path: String) -> Result<Int32, MihomoControllerError> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.connectFailed(errnoDescription())) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else {
            close(fd)
            return .failure(.connectFailed("路径过长"))
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: socketPath.utf8)
            raw[socketPath.utf8.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let reason = errnoDescription()
            close(fd)
            return .failure(.connectFailed(reason))
        }
        let request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        let sent = request.utf8CString.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count - 1, 0) }
        guard sent >= 0 else {
            let reason = errnoDescription()
            close(fd)
            return .failure(.connectFailed(reason))
        }
        return .success(fd)
    }

    private static func read(_ fd: Int32, deadline: Date) -> ReadResult {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return .timedOut }
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&entry, 1, Int32(max(1, (remaining * 1000).rounded(.up))))
        if ready < 0 { return errno == EINTR ? .timedOut : .failed(errnoDescription()) }
        if ready == 0 { return .timedOut }
        var chunk = [UInt8](repeating: 0, count: 8192)
        let count = recv(fd, &chunk, chunk.count, 0)
        if count < 0 { return errno == EINTR || errno == EAGAIN ? .timedOut : .failed(errnoDescription()) }
        if count == 0 { return .closed }
        return .data(Data(chunk[0..<count]))
    }

    /// 解析完整应答（`Connection: close`）。支持分块传输和普通正文。
    static func parse(_ data: Data) -> Response? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        let statusLine = header.components(separatedBy: "\r\n").first ?? ""
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var body = Data(data[end.upperBound...])
        if header.lowercased().contains("transfer-encoding: chunked") {
            var decoder = ChunkedDecoder()
            body = decoder.feed(body)
        }
        return Response(status: status, body: body)
    }
}

/// 分块传输解码器：可以分多次喂入数据。
struct ChunkedDecoder {
    private var buffer = Data()
    private var remaining = 0
    private var skipCRLF = false

    mutating func feed(_ data: Data) -> Data {
        buffer.append(data)
        var output = Data()
        while true {
            if skipCRLF {
                guard buffer.count >= 2 else { break }
                buffer.removeFirst(2)
                skipCRLF = false
            }
            if remaining > 0 {
                let take = min(remaining, buffer.count)
                guard take > 0 else { break }
                output.append(buffer.prefix(take))
                buffer.removeFirst(take)
                remaining -= take
                if remaining == 0 { skipCRLF = true }
                continue
            }
            guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else { break }
            let sizeText = String(decoding: buffer[..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            buffer.removeSubrange(..<lineEnd.upperBound)
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            remaining = size
        }
        return output
    }
}
