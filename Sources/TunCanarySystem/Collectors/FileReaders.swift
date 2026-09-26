import Darwin
import Foundation
import TunCanaryCore

/// 本地文件读取结果：区分“不存在”和“存在但不可读”。
public enum LocalFileReadResult: Sendable, Equatable {
    case data(Data)
    /// 文件或其所在目录不存在。
    case missing
    /// 存在但不可读（权限不足、不是普通文件、过大等），带中文原因。
    case failed(String)
}

/// 只读方式读取小文件（POSIX open/read，按 errno 区分失败原因）。
public enum LocalFileReader {
    /// 默认上限 16 MB（Clash 配置含节点列表时可能较大）。
    public static let defaultMaxBytes = 16 << 20

    public static func read(_ path: String, maxBytes: Int = defaultMaxBytes) -> LocalFileReadResult {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return failure(errno) }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { return failure(errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failed("不是普通文件") }
        guard info.st_size <= off_t(maxBytes) else { return .failed("文件过大（\(info.st_size) 字节）") }

        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                if data.count > maxBytes { return .failed("文件过大") }
                continue
            }
            if count == 0 { break }
            if errno == EINTR || errno == EAGAIN { continue }
            return failure(errno)
        }
        return .data(data)
    }

    static func failure(_ code: Int32) -> LocalFileReadResult {
        switch code {
        case ENOENT, ENOTDIR:
            return .missing
        case EACCES, EPERM:
            return .failed("权限不足")
        case EISDIR:
            return .failed("不是普通文件")
        default:
            return .failed("读取失败（\(errnoDescription(code))）")
        }
    }
}

/// 读取 Clash Verge 的 `verge.yaml` 与 `clash-verge.yaml`，文本交给 `ClashConfigParser`。
///
/// 原文只在本函数内短暂存在，不保留、不打印、不写日志（其中含 secret）。
/// 任一文件缺失或不可读都记为 `.failed`，原因只写文件名，不写完整路径。
public struct ClashConfigReader: Sendable {
    public let paths: KnownPaths

    public init(paths: KnownPaths) {
        self.paths = paths
    }

    public func read() -> Collected<ClashConfig> {
        var reasons: [String] = []
        let verge = text(at: paths.vergeConfigFile, name: "verge.yaml", reasons: &reasons)
        let clash = text(at: paths.clashVergeConfigFile, name: "clash-verge.yaml", reasons: &reasons)
        guard reasons.isEmpty else {
            return .failed(reason: reasons.joined(separator: "；"))
        }
        return .collected(ClashConfigParser.parse(vergeYAML: verge, clashVergeYAML: clash))
    }

    private func text(at path: String, name: String, reasons: inout [String]) -> String? {
        switch LocalFileReader.read(path) {
        case .missing:
            reasons.append("未找到 \(name)")
            return nil
        case .failed(let reason):
            reasons.append("无法读取 \(name)：\(reason)")
            return nil
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                reasons.append("\(name) 不是 UTF-8 文本")
                return nil
            }
            return text
        }
    }
}

/// 读取 VPN 适配器的状态文件，只取配置指定的字段。
public struct VPNStatusFileReader: Sendable {
    /// 状态文件大小上限。
    public static let maxBytes = 1 << 20

    public let path: String
    public let fields: VPNAdapterConfig.StatusFile

    public init(path: String, fields: VPNAdapterConfig.StatusFile) {
        self.path = path
        self.fields = fields
    }

    public func read() -> VPNStatusFileState {
        switch LocalFileReader.read(path, maxBytes: Self.maxBytes) {
        case .missing:
            return .missing
        case .failed(let reason):
            return .unreadable(reason: reason)
        case .data(let data):
            do {
                return .present(try VPNStatusFileParser.parse(data, fields: fields))
            } catch let error as VPNStatusFileParseError {
                return .unreadable(reason: error.message)
            } catch {
                return .unreadable(reason: "解析失败")
            }
        }
    }
}
