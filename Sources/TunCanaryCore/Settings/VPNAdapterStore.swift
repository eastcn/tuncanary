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
/// 配置只在进程启动时读取；修改后需重启应用。按文件名排序，校验失败或 ID 重复的文件被跳过并记入 `problems`。
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

    public func load() -> VPNAdapterSet {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return VPNAdapterSet()
        }
        var result = VPNAdapterSet()
        var ids = Set<String>()
        for name in names.filter({ $0.hasSuffix(".json") && !$0.hasPrefix(".") }).sorted() {
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
