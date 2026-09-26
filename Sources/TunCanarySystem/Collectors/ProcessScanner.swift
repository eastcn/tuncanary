import Darwin
import Foundation
import TunCanaryCore

/// 判断进程是否相关：只按可执行文件路径识别，从不看命令行。
///
/// - `verge-mihomo`、`clash-verge`：按可执行文件名（路径最后一段）识别。
/// - VPN 适配器：与配置中展开后的可执行文件路径精确比较。比较前去掉
///   `/System/Volumes/Data` 前缀并解析配置路径中的符号链接；匹配后路径改写成配置的写法，
///   保证 Core 判定时的精确比较成立。
public struct RelevantProcessMatcher: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case mihomo
        case clashVerge
        /// 参数为适配器 ID。
        case vpn(String)
    }

    /// Clash Verge 主程序的可执行文件名。
    public static let clashVergeProcessName = "clash-verge"

    /// 规范化后的路径 → （适配器 ID，配置中的写法）。
    private let vpnAliases: [String: VPNPath]

    private struct VPNPath: Sendable, Equatable {
        var adapterID: String
        var path: String
    }

    public init(paths: KnownPaths, adapters: [VPNAdapterConfig] = []) {
        var aliases: [String: VPNPath] = [:]
        for adapter in adapters {
            for known in adapter.executablePaths(home: paths.homeDirectory) {
                let entry = VPNPath(adapterID: adapter.id, path: known)
                if aliases[Self.normalize(known)] == nil { aliases[Self.normalize(known)] = entry }
                let resolved = URL(fileURLWithPath: known).resolvingSymlinksInPath().path
                if aliases[Self.normalize(resolved)] == nil { aliases[Self.normalize(resolved)] = entry }
            }
        }
        vpnAliases = aliases
    }

    /// 匹配结果：种类与写入 `ProcessEntry` 的路径；不相关时为 nil。
    public func match(executablePath path: String) -> (kind: Kind, path: String)? {
        guard !path.isEmpty else { return nil }
        if let known = vpnAliases[Self.normalize(path)] {
            return (.vpn(known.adapterID), known.path)
        }
        switch (path as NSString).lastPathComponent {
        case KnownPaths.mihomoProcessName:
            return (.mihomo, path)
        case Self.clashVergeProcessName:
            return (.clashVerge, path)
        default:
            return nil
        }
    }

    /// 去掉数据卷前缀（firmlink 的另一种写法）。
    static func normalize(_ path: String) -> String {
        let dataVolume = "/System/Volumes/Data"
        if path.hasPrefix(dataVolume + "/") {
            return String(path.dropFirst(dataVolume.count))
        }
        return path
    }
}

/// 进程扫描：`proc_listpids` 列出 pid，`proc_pidpath` 取可执行文件路径。
///
/// 实测（macOS 26.6，普通用户）：`proc_pidpath` 对 root 进程同样可用（verge-mihomo 以 root 运行，
/// 能取到 `/Library/Application Support/clash-verge-service/cores/verge-mihomo`），无需提权或改用 sysctl。
/// 取不到路径的只有已退出的进程（ESRCH）和可执行文件已被删除的进程（ENOENT）。
public struct ProcessScanner: Sendable {
    public init() {}

    /// 列出全部进程（按 pid 升序），取不到路径的 `executablePath` 为 nil。
    public func listAll() throws -> [ProcessEntry] {
        try Self.listPIDs().map { ProcessEntry(pid: $0, executablePath: Self.executablePath(of: $0)) }
    }

    /// 只保留相关进程（verge-mihomo、clash-verge、VPN 适配器的进程），按 pid 升序。
    /// - Parameter extraNames: 另外按可执行文件名保留的进程，例如手动模式的代理核心。
    public func relevantProcesses(matcher: RelevantProcessMatcher, extraNames: [String] = []) throws -> [ProcessEntry] {
        let extra = Set(extraNames)
        var result: [ProcessEntry] = []
        var buffer = [CChar](repeating: 0, count: Self.pathBufferSize)
        for pid in try Self.listPIDs() {
            guard let path = Self.executablePath(of: pid, buffer: &buffer) else { continue }
            if let matched = matcher.match(executablePath: path) {
                result.append(ProcessEntry(pid: pid, executablePath: matched.path))
            } else if !extra.isEmpty, extra.contains((path as NSString).lastPathComponent) {
                result.append(ProcessEntry(pid: pid, executablePath: path))
            }
        }
        return result
    }

    /// `PROC_PIDPATHINFO_MAXSIZE`（4 × MAXPATHLEN），宏不能直接导入 Swift。
    static let pathBufferSize = Int(4 * MAXPATHLEN)

    /// 全部 pid（去掉 0），升序。
    static func listPIDs() throws -> [pid_t] {
        let estimate = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard estimate > 0 else {
            throw SystemCollectionError("proc_listpids 失败（\(errnoDescription())）")
        }
        // 两次调用之间可能有新进程，预留余量。
        let capacity = Int(estimate) / MemoryLayout<pid_t>.stride + 256
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = pids.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, Int32(raw.count))
        }
        guard bytes > 0 else {
            throw SystemCollectionError("proc_listpids 失败（\(errnoDescription())）")
        }
        let count = min(capacity, Int(bytes) / MemoryLayout<pid_t>.stride)
        return pids.prefix(count).filter { $0 > 0 }.sorted()
    }

    /// 单个进程的可执行文件路径；进程已退出或无权限时为 nil。
    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        return executablePath(of: pid, buffer: &buffer)
    }

    static func executablePath(of pid: pid_t, buffer: inout [CChar]) -> String? {
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
