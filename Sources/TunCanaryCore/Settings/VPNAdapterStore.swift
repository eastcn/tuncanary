import Foundation

/// 已加载的 VPN 适配器配置，以及无法使用的配置文件说明。
public struct VPNAdapterSet: Sendable, Equatable {
    public var adapters: [VPNAdapterConfig]
    /// 每条形如 “example.json：id 须为 …”，供诊断展示。
    public var problems: [String]

    public init(adapters: [VPNAdapterConfig] = [], problems: [String] = []) {
        self.adapters = adapters
        self.problems = problems
    }
}

/// 从目录读取声明式 VPN 适配器配置（每个 `.json` 文件一个）。与 `SettingsStore` 一样属于 Core 中的 I/O。
///
/// 按文件名排序，校验失败或 ID 重复的文件被跳过并记入 `problems`。
/// 菜单栏应用通过 `VPNAdapterRegistry` 在目录变化后重新加载；命令行每次运行都重新读取。
public struct VPNAdapterStore: Sendable {
    /// 单个配置文件的大小上限。
    public static let maxFileBytes = 64 * 1024
    /// 最多加载的适配器数。
    public static let maxAdapters = 10

    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    public init(paths: KnownPaths = .currentUser()) {
        self.init(directory: paths.vpnAdaptersDirectory)
    }

    /// 目录内容的指纹：每个 `.json` 文件的名称、inode、大小与修改时间。目录不存在时为空。
    public struct Fingerprint: Sendable, Equatable {
        public struct Entry: Sendable, Equatable {
            public var name: String
            public var inode: UInt64
            public var size: UInt64
            public var modified: TimeInterval
        }

        public var entries: [Entry]
    }

    /// 只读取文件属性，不读取内容，每轮检查调用的开销很小。
    public func fingerprint() -> Fingerprint {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return Fingerprint(entries: [])
        }
        let entries = Self.candidateNames(names).map { name -> Fingerprint.Entry in
            let attributes = (try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path)) ?? [:]
            return Fingerprint.Entry(
                name: name,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        }
        return Fingerprint(entries: entries)
    }

    /// 参与加载的文件名：`.json` 结尾、不以 `.` 开头，按文件名排序。
    static func candidateNames(_ names: [String]) -> [String] {
        names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
    }

    public func load() -> VPNAdapterSet {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return VPNAdapterSet()
        }
        var result = VPNAdapterSet()
        var ids = Set<String>()
        for name in Self.candidateNames(names) {
            let fileURL = url.appendingPathComponent(name)
            switch Self.decode(contentsOf: fileURL) {
            case .failure(let error):
                result.problems.append("\(name)：\(error.message)")
            case .success(let config):
                if ids.contains(config.id) {
                    result.problems.append("\(name)：\(VPNAdapterConfigError.idDuplicate(config.id).message)")
                } else if result.adapters.count >= Self.maxAdapters {
                    result.problems.append("\(name)：最多加载 \(Self.maxAdapters) 个适配器")
                } else {
                    ids.insert(config.id)
                    result.adapters.append(config)
                }
            }
        }
        return result
    }

    static func decode(contentsOf url: URL) -> Result<VPNAdapterConfig, VPNAdapterConfigError> {
        guard let data = try? Data(contentsOf: url), data.count <= maxFileBytes else {
            return .failure(.invalidJSON("无法读取或文件过大"))
        }
        return decode(data)
    }

    /// 解码并校验一份配置。
    public static func decode(_ data: Data) -> Result<VPNAdapterConfig, VPNAdapterConfigError> {
        let config: VPNAdapterConfig
        do {
            config = try JSONDecoder().decode(VPNAdapterConfig.self, from: data)
        } catch let error as DecodingError {
            return .failure(.invalidJSON(describe(error)))
        } catch {
            return .failure(.invalidJSON("格式错误"))
        }
        if let first = config.validate().first {
            return .failure(first)
        }
        return .success(config)
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): return "缺少字段 \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "字段类型不符" : "字段 \(path) 类型不符"
        case .dataCorrupted: return "不是有效的 JSON"
        @unknown default: return "格式错误"
        }
    }
}

/// 菜单栏应用持有的当前适配器集合。每轮检查前比对目录指纹，变化时重新加载；也可以强制重新加载。
///
/// 采集线程与主 actor 都会读取，内部用锁保护。
public final class VPNAdapterRegistry: @unchecked Sendable {
    public let store: VPNAdapterStore

    private let lock = NSLock()
    private var set: VPNAdapterSet
    private var fingerprint: VPNAdapterStore.Fingerprint

    public init(store: VPNAdapterStore) {
        self.store = store
        // 先取指纹再加载：两者之间文件若有变化，下一次比对会发现并重新加载。
        fingerprint = store.fingerprint()
        set = store.load()
    }

    /// 当前适配器集合。
    public var current: VPNAdapterSet {
        lock.lock()
        defer { lock.unlock() }
        return set
    }

    /// 目录指纹变化时重新加载并返回新集合；没有变化时返回 nil。
    public func reloadIfChanged() -> VPNAdapterSet? {
        let latest = store.fingerprint()
        lock.lock()
        let unchanged = latest == fingerprint
        lock.unlock()
        if unchanged { return nil }
        return install(fingerprint: latest)
    }

    /// 不比对指纹，强制重新加载。
    @discardableResult
    public func reload() -> VPNAdapterSet {
        install(fingerprint: store.fingerprint())
    }

    private func install(fingerprint latest: VPNAdapterStore.Fingerprint) -> VPNAdapterSet {
        let loaded = store.load()
        lock.lock()
        defer { lock.unlock() }
        fingerprint = latest
        set = loaded
        return loaded
    }
}
