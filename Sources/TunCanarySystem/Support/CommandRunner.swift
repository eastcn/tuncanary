import Darwin
import Foundation

/// 只读命令的执行结果。
public struct CommandResult: Sendable, Equatable {
    /// 结束方式。
    public enum Termination: Sendable, Equatable {
        /// 正常退出，带退出码。
        case exited(Int32)
        /// 被信号终止（非本工具超时所致）。
        case signaled(Int32)
        /// 超时，子进程组已被终止。
        case timedOut
        /// 无法启动（路径不存在、无执行权限等）。
        case launchFailed(String)
    }

    public var termination: Termination
    public var standardOutput: Data
    public var standardError: Data
    /// 输出超过上限被截断。
    public var outputTruncated: Bool
    /// 耗时（秒）。
    public var duration: TimeInterval

    public init(
        termination: Termination,
        standardOutput: Data = Data(),
        standardError: Data = Data(),
        outputTruncated: Bool = false,
        duration: TimeInterval = 0
    ) {
        self.termination = termination
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.outputTruncated = outputTruncated
        self.duration = duration
    }

    public var outputText: String { String(decoding: standardOutput, as: UTF8.self) }
    public var errorText: String { String(decoding: standardError, as: UTF8.self) }

    /// 退出码为 0。
    public var succeeded: Bool { termination == .exited(0) }

    /// 失败时的中文原因（成功时为 nil），`name` 为展示用的命令名。
    public func failureReason(name: String, timeout: TimeInterval) -> String? {
        switch termination {
        case .exited(0):
            return nil
        case .exited(let code):
            return "\(name) 退出码 \(code)"
        case .signaled(let signal):
            return "\(name) 被信号 \(signal) 终止"
        case .timedOut:
            let seconds = timeout == timeout.rounded() ? String(Int(timeout)) : String(format: "%.1f", timeout)
            return "\(name) 超时（\(seconds) 秒）"
        case .launchFailed(let reason):
            return "无法启动 \(name)：\(reason)"
        }
    }
}

/// 带超时的命令执行工具。
///
/// - 用 `posix_spawn` 启动，子进程自成进程组，stdin 接 `/dev/null`，只继承 stdout/stderr 两个管道。
/// - 父进程用 `poll` 同时读取两个管道，任一管道写满都不会阻塞子进程，避免输出较大时死锁。
/// - 超时后向整个进程组发 SIGTERM，200 ms 后仍未退出再发 SIGKILL，并回收子进程。
/// - `run` 是阻塞调用，可在任意线程执行；`runAsync` 在 GCD 全局队列上执行。
public struct CommandRunner: Sendable {
    /// 单个输出流的最大保留字节数，超出部分读取后丢弃。
    public var maxOutputBytes: Int
    /// 子进程环境变量（`KEY=VALUE`）。默认固定 `LC_ALL=C`，保证输出格式稳定。
    public var environment: [String]

    public static let defaultEnvironment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C"]

    public init(maxOutputBytes: Int = 8 << 20, environment: [String] = CommandRunner.defaultEnvironment) {
        self.maxOutputBytes = max(0, maxOutputBytes)
        self.environment = environment
    }

    /// 在后台队列执行命令。
    public func runAsync(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval) async -> CommandResult {
        let runner = self
        return await Blocking.run { runner.run(executable, arguments, timeout: timeout) }
    }

    /// 阻塞执行命令，最多等待 `timeout` 秒。
    public func run(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval) -> CommandResult {
        let started = Monotonic.now()
        let deadline = started + max(0, timeout)

        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else {
            return CommandResult(termination: .launchFailed("创建管道失败（\(errnoDescription())）"))
        }
        guard pipe(&errPipe) == 0 else {
            let reason = errnoDescription()
            close(outPipe[0]); close(outPipe[1])
            return CommandResult(termination: .launchFailed("创建管道失败（\(reason)）"))
        }
        // 父进程侧的描述符都设 CLOEXEC，避免被并发启动的其他子进程继承。
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        let spawn = Self.spawn(executable, arguments, environment: environment,
                               stdoutWrite: outPipe[1], stderrWrite: errPipe[1])
        close(outPipe[1])
        close(errPipe[1])
        let pid: pid_t
        switch spawn {
        case .success(let value):
            pid = value
        case .failure(let error):
            close(outPipe[0]); close(errPipe[0])
            return CommandResult(termination: .launchFailed(error.message), duration: Monotonic.now() - started)
        }

        var output = OutputCollector(limit: maxOutputBytes)
        let finishedReading = Self.drain(stdoutFD: outPipe[0], stderrFD: errPipe[0], deadline: deadline, into: &output)

        let termination: CommandResult.Termination
        if finishedReading, let status = Self.waitForExit(pid, until: deadline) {
            termination = Self.decode(status)
        } else {
            // 管道未读完（含孙进程占着管道）或子进程未退出：终止整个进程组。
            Self.terminateGroup(pid)
            termination = .timedOut
        }

        return CommandResult(
            termination: termination,
            standardOutput: output.stdout,
            standardError: output.stderr,
            outputTruncated: output.truncated,
            duration: Monotonic.now() - started
        )
    }

    // MARK: - 启动

    private static func spawn(
        _ executable: String,
        _ arguments: [String],
        environment: [String],
        stdoutWrite: Int32,
        stderrWrite: Int32
    ) -> Result<pid_t, SystemCollectionError> {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // 子进程：清空信号屏蔽字，常见信号恢复默认处理。
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGALRM, SIGTERM, SIGCHLD, SIGUSR1, SIGUSR2] {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        // 自成进程组（pgid = pid），超时时可以连同孙进程一起终止。
        posix_spawnattr_setpgroup(&attributes, 0)
        // CLOEXEC_DEFAULT：只继承 file actions 中显式设置的 0/1/2。
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard code == 0 else {
            return .failure(SystemCollectionError(errnoDescription(code)))
        }
        return .success(pid)
    }

    // MARK: - 读取

    /// 两个输出流的累积结果。
    struct OutputCollector {
        let limit: Int
        var stdout = Data()
        var stderr = Data()
        var truncated = false

        init(limit: Int) {
            self.limit = limit
        }

        mutating func append(_ bytes: UnsafeRawBufferPointer, toStderr: Bool) {
            let current = toStderr ? stderr.count : stdout.count
            let room = max(0, limit - current)
            let kept = min(room, bytes.count)
            if kept < bytes.count { truncated = true }
            guard kept > 0, let base = bytes.baseAddress else { return }
            if toStderr {
                stderr.append(base.assumingMemoryBound(to: UInt8.self), count: kept)
            } else {
                stdout.append(base.assumingMemoryBound(to: UInt8.self), count: kept)
            }
        }
    }

    /// 读取两个管道直到都遇到 EOF（返回 true）或到达截止时间（返回 false）。返回时两个描述符均已关闭。
    private static func drain(stdoutFD: Int32, stderrFD: Int32, deadline: TimeInterval, into output: inout OutputCollector) -> Bool {
        for fd in [stdoutFD, stderrFD] {
            let current = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, current | O_NONBLOCK)
        }
        var open: [Int32] = [stdoutFD, stderrFD]
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        defer { for fd in open { close(fd) } }

        while !open.isEmpty {
            let remaining = deadline - Monotonic.now()
            if remaining <= 0 { return false }
            var pollSet = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let milliseconds = Int32(min(max(1, (remaining * 1000).rounded(.up)), 60_000))
            let ready = poll(&pollSet, nfds_t(pollSet.count), milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            if ready == 0 { continue }

            for entry in pollSet where entry.revents != 0 {
                let fd = entry.fd
                let isStderr = fd == stderrFD
                var reachedEnd = false
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if count > 0 {
                        buffer.withUnsafeBytes { raw in
                            output.append(UnsafeRawBufferPointer(rebasing: raw[0..<count]), toStderr: isStderr)
                        }
                        continue
                    }
                    if count == 0 {
                        reachedEnd = true
                    } else if errno == EINTR {
                        continue
                    } else if errno != EAGAIN && errno != EWOULDBLOCK {
                        reachedEnd = true
                    }
                    break
                }
                if reachedEnd || entry.revents & Int16(POLLNVAL) != 0 {
                    close(fd)
                    open.removeAll { $0 == fd }
                }
            }
        }
        return true
    }

    // MARK: - 回收

    /// 在截止时间前等待子进程退出，返回 wait 状态；超时返回 nil。
    private static func waitForExit(_ pid: pid_t, until deadline: TimeInterval) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return status }
            if result < 0 {
                if errno == EINTR { continue }
                // ECHILD：已被回收（不应发生），按正常退出处理。
                return 0
            }
            if Monotonic.now() >= deadline { return nil }
            usleep(2_000)
        }
    }

    /// 子进程是否已退出（不回收，僵尸状态保留 pid 与进程组号）。
    private static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        return result == 0 && info.si_pid == pid
    }

    /// 终止整个进程组并回收子进程。调用时子进程尚未被回收。
    private static func terminateGroup(_ pid: pid_t) {
        _ = kill(-pid, SIGTERM)
        let graceEnd = Monotonic.now() + 0.2
        while !hasExited(pid) && Monotonic.now() < graceEnd { usleep(5_000) }
        // 组长即使已退出也尚未回收，进程组号不会被复用，此时向整个组发 SIGKILL 是安全的。
        _ = kill(-pid, SIGKILL)
        if waitForExit(pid, until: Monotonic.now() + 1.0) != nil { return }
        // 极少数情况下子进程处于不可中断状态：交给后台线程阻塞回收，避免僵尸进程。
        DispatchQueue.global(qos: .background).async {
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }
    }

    /// 解析 wait 状态（Swift 中没有 WIFEXITED 等宏）。
    public static func decode(_ status: Int32) -> CommandResult.Termination {
        let signal = status & 0x7f
        if signal == 0 {
            return .exited((status >> 8) & 0xff)
        }
        return .signaled(signal)
    }
}
