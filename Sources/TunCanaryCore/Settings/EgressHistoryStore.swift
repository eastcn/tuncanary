import Foundation

/// 出口历史含完整公网 IP，只在本机保存。写入失败明确反馈，不影响网络检查。
public final class EgressHistoryStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private var lastWrittenRevision = -1
    public init(fileURL: URL) { self.fileURL = fileURL }
    public convenience init(paths: KnownPaths = .currentUser()) {
        self.init(fileURL: URL(fileURLWithPath: paths.faultEventLogFile).deletingLastPathComponent().appendingPathComponent("egress-history.json"))
    }
    public func load(at now: Date) -> EgressMonitorState {
        lock.lock(); defer { lock.unlock() }
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 * 1024,
              let data = try? Data(contentsOf: fileURL),
              var state = try? JSONDecoder().decode(EgressMonitorState.self, from: data) else { return EgressMonitorState() }
        state.prune(at: now)
        return state
    }
    public func save(_ state: EgressMonitorState, revision: Int = 0) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard revision >= lastWrittenRevision else { return true }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastWrittenRevision = revision
            return true
        } catch { return false }
    }
}
