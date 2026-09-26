import Foundation

/// 通过 `#filePath` 推算仓库根目录，定位 `Tests/Fixtures`。
enum TestPaths {
    /// 仓库根目录（本文件位于 Sources/TunCanarySelfTest/Support/）。
    static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // TunCanarySelfTest
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // 仓库根
    }()

    static var fixtures: URL {
        repoRoot.appendingPathComponent("Tests/Fixtures", isDirectory: true)
    }

    /// 合成快照目录。
    static var synthetic: URL {
        fixtures.appendingPathComponent("synthetic", isDirectory: true)
    }

    /// 读取 fixture 文本；不存在时返回 nil。
    static func text(_ relativePath: String) -> String? {
        try? String(contentsOf: fixtures.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
