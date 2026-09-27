import Foundation

/// 故障事件日志：JSON Lines 文件，每行一条 `FaultEvent`。与 `SettingsStore` 一样属于 Core 中的 I/O。
///
/// - 最多保留 `maxEvents` 条，每次写入都整体重写并原子替换。
/// - 读不到文件、文件过大或某行无法解码时跳过，不报错。
/// - 事件描述在写入前已脱敏；文件只在本机，不上传。
public final class FaultEventStore: @unchecked Sendable {
    public static let maxEvents = 200
    /// 读取时的文件大小上限。
    public static let maxFileBytes = 1024 * 1024

    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public convenience init(paths: KnownPaths = .currentUser()) {
        self.init(fileURL: URL(fileURLWithPath: paths.faultEventLogFile))
    }

    /// 最近的事件（旧 → 新），最多 `limit` 条。
    public func recent(limit: Int = maxEvents) -> [FaultEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(readAll().suffix(max(0, limit)))
    }

    /// 追加事件。写入失败时静默放弃：事件日志只用于回看，不影响检查。
    public func append(_ events: [FaultEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let kept = Array((readAll() + events).suffix(Self.maxEvents))
        let encoder = Self.encoder()
        var data = Data()
        for event in kept {
            guard let line = try? encoder.encode(event) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }

    private func readAll() -> [FaultEvent] {
        guard let data = try? Data(contentsOf: fileURL), data.count <= Self.maxFileBytes else { return [] }
        let decoder = Self.decoder()
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(FaultEvent.self, from: Data(line))
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
