import AppKit
import Darwin
import Foundation
import TunCanaryCore

/// 仅应用模式持锁；CLI 检查与正在运行的菜单栏应用互不影响。
///
/// 锁文件放在 `~/Library/Application Support/TunCanary/`，不会像临时目录那样被系统清理。
/// 另外按 bundle id 检查是否已有其他进程的实例在运行，覆盖锁文件丢失或旧版本仍持旧锁的情况。
public final class ApplicationInstance {
    public static let showNotification = Notification.Name(AppIdentity.bundleID + ".show")

    /// 默认锁文件位置：`~/Library/Application Support/TunCanary/instance.lock`。
    public static var defaultLockURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TunCanary", isDirectory: true)
            .appendingPathComponent("instance.lock")
    }

    /// 是否已有其他 pid 的同 bundle id 实例在运行。
    public static func otherInstanceRunning() -> Bool {
        let current = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleID)
            .contains { $0.processIdentifier != current && !$0.isTerminated }
    }

    public let isPrimary: Bool
    private let descriptor: Int32

    /// - Parameters:
    ///   - lockURL: 锁文件路径；所在目录不存在时以 700 权限创建。
    ///   - otherInstanceRunning: 检查其他实例，测试可注入。
    public init(lockURL: URL = ApplicationInstance.defaultLockURL,
                otherInstanceRunning: () -> Bool = ApplicationInstance.otherInstanceRunning) throws {
        let directory = lockURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            // 取得锁后再确认没有其他实例，避免锁文件丢失时出现第二个实例。
            isPrimary = !otherInstanceRunning()
        } else {
            let error = errno
            if error == EWOULDBLOCK { isPrimary = false }
            else {
                Darwin.close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
        }
    }

    deinit { Darwin.close(descriptor) }
}
