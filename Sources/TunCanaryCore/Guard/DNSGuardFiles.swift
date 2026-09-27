import Foundation

// DNS 守护进程的文件格式。守护进程是单独安装的可选组件，以 root 身份运行，负责写入保存的 DNS；
// 菜单栏应用只读取这里定义的配置、状态文件和事件日志，用于展示，不参与判定。

/// 守护进程的安装路径。全部位于系统目录，由 root 所有，普通用户只读。
public struct DNSGuardPaths: Sendable, Equatable {
    /// LaunchDaemon 的 label，也是 plist 的文件名。
    public static let label = AppIdentity.bundleID + ".dns-guard"

    /// 根目录，正式环境为 `/`；测试中指向临时目录。
    public let root: String

    public init(root: String = "/") {
        var value = root
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        self.root = value
    }

    private func path(_ relative: String) -> String {
        (root == "/" ? "" : root) + "/" + relative
    }

    /// `/Library/Application Support/TunCanary`。
    public var supportDirectory: String { path("Library/Application Support/\(AppIdentity.name)") }
    public var executableFile: String { supportDirectory + "/bin/tuncanary-dns-guard" }
    public var configFile: String { supportDirectory + "/dns-guard.json" }
    public var stateFile: String { supportDirectory + "/dns-guard-state.json" }
    public var eventLogFile: String { supportDirectory + "/dns-guard-events.jsonl" }
    public var launchDaemonFile: String { path("Library/LaunchDaemons/\(Self.label).plist") }
}

/// 守护进程运行时所处的阶段。
public enum DNSGuardPhase: String, Sendable, Equatable, Codable {
    /// 阶段 A：VPN 已断开。
    case disconnected
    /// 阶段 B：VPN 已连接，连接期接管。
    case connected

    public var displayName: String {
        switch self {
        case .disconnected: return "断开期"
        case .connected: return "连接期"
        }
    }
}

/// 守护进程一次运行的结果。
public enum DNSGuardOutcome: String, Sendable, Equatable, Codable {
    /// 条件不满足，跳过。
    case skipped
    /// 保存的 DNS 已等于目标值，只读退出。
    case compliant
    /// 写入，并且读回确认成功。
    case written
    /// 写入失败。
    case writeFailed
    /// 写入后读回的值与目标值不一致。
    case verifyFailed
    /// 连续失败后的退避期，只记录不写入。
    case backoff
    /// 连接期写入次数达到上限，停用连接期接管，直到 VPN 下次断开。
    case takeoverSuspended

    public var displayName: String {
        switch self {
        case .skipped: return "跳过"
        case .compliant: return "已符合，未写入"
        case .written: return "写入并读回成功"
        case .writeFailed: return "写入失败"
        case .verifyFailed: return "写入后读回不一致"
        case .backoff: return "连续失败，退避中"
        case .takeoverSuspended: return "连接期写入过于频繁，已停用连接期接管"
        }
    }

    /// 展示用的严重程度。只用于守护进程这一行，不影响状态卡的判定。
    public var severity: Severity {
        switch self {
        case .compliant, .written: return .ok
        case .skipped: return .unknown
        case .writeFailed, .verifyFailed, .backoff, .takeoverSuspended: return .warning
        }
    }
}

/// 事件日志（JSON Lines）中的一条，也用作状态文件中的“最近一次”记录。
///
/// 只记录时间、阶段、结果和原因。原因在写入前已经脱敏，不含内网探针域名、VPN 状态文件原文和代理配置原文。
public struct DNSGuardEvent: Sendable, Equatable, Codable {
    public var date: Date
    /// 未进入任何阶段就跳过时为 nil（例如 TUN 未运行）。
    public var phase: DNSGuardPhase?
    public var outcome: DNSGuardOutcome
    /// 跳过或失败的原因。
    public var reason: String?

    public init(date: Date, phase: DNSGuardPhase? = nil, outcome: DNSGuardOutcome, reason: String? = nil) {
        self.date = date
        self.phase = phase
        self.outcome = outcome
        self.reason = reason
    }

    /// 一行展示文本，例如“断开期：写入并读回成功”“跳过：TUN 未运行”。
    public var text: String {
        var text = phase.map { "\($0.displayName)：" } ?? ""
        text += outcome.displayName
        if let reason, !reason.isEmpty { text += "（\(reason)）" }
        return text
    }
}

/// 状态文件：最近结果、连续失败次数和最近一次写入。
public struct DNSGuardState: Sendable, Equatable, Codable {
    /// 最近一次运行。
    public var lastRun: DNSGuardEvent?
    /// 最近一次尝试写入（成功或失败）。
    public var lastWrite: DNSGuardEvent?
    public var consecutiveFailures: Int
    /// 退避结束时间；不在退避期为 nil。
    public var backoffUntil: Date?
    /// 连接期接管是否因写入过于频繁而停用。
    public var connectedTakeoverSuspended: Bool

    public init(lastRun: DNSGuardEvent? = nil, lastWrite: DNSGuardEvent? = nil, consecutiveFailures: Int = 0,
                backoffUntil: Date? = nil, connectedTakeoverSuspended: Bool = false) {
        self.lastRun = lastRun
        self.lastWrite = lastWrite
        self.consecutiveFailures = consecutiveFailures
        self.backoffUntil = backoffUntil
        self.connectedTakeoverSuspended = connectedTakeoverSuspended
    }

    private enum CodingKeys: String, CodingKey {
        case lastRun, lastWrite, consecutiveFailures, backoffUntil, connectedTakeoverSuspended
    }

    /// 缺少的字段取默认值，便于以后追加字段。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lastRun = try values.decodeIfPresent(DNSGuardEvent.self, forKey: .lastRun)
        lastWrite = try values.decodeIfPresent(DNSGuardEvent.self, forKey: .lastWrite)
        consecutiveFailures = try values.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        backoffUntil = try values.decodeIfPresent(Date.self, forKey: .backoffUntil)
        connectedTakeoverSuspended = try values.decodeIfPresent(Bool.self, forKey: .connectedTakeoverSuspended) ?? false
    }
}

/// 守护进程配置中菜单栏应用关心的部分：目标 DNS 和是否启用连接期接管。其余字段忽略。
public struct DNSGuardConfigSummary: Sendable, Equatable {
    /// 规范化后的目标 DNS。
    public var targetDNS: [String]
    public var connectedTakeoverEnabled: Bool

    public init(targetDNS: [String], connectedTakeoverEnabled: Bool = false) {
        self.targetDNS = DNSList.normalize(targetDNS)
        self.connectedTakeoverEnabled = connectedTakeoverEnabled
    }
}

/// 一轮采集读到的守护进程信息。
public struct DNSGuardSnapshot: Sendable, Equatable {
    /// LaunchDaemon 是否存在。
    public var installed: Bool
    /// 配置；未安装时为 `.notCollected`。
    public var config: Collected<DNSGuardConfigSummary>
    /// 状态文件；守护进程尚未运行过时为 `.notCollected`。
    public var state: Collected<DNSGuardState>
    /// 最近的事件（旧 → 新）。
    public var recentEvents: [DNSGuardEvent]

    public init(installed: Bool, config: Collected<DNSGuardConfigSummary> = .notCollected,
                state: Collected<DNSGuardState> = .notCollected, recentEvents: [DNSGuardEvent] = []) {
        self.installed = installed
        self.config = config
        self.state = state
        self.recentEvents = recentEvents
    }

    public static let notInstalled = DNSGuardSnapshot(installed: false)
}

/// 守护进程文件的解析（纯函数）。日期为 ISO 8601。
public enum DNSGuardFileParser {
    /// 解析失败的中文原因。
    public struct ParseError: Error, Equatable, Sendable {
        public var message: String
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private struct RawConfig: Decodable {
        struct Takeover: Decodable {
            var enabled: Bool?
        }

        var targetDNS: [String]?
        var connectedTakeover: Takeover?
    }

    public static func parseConfig(_ data: Data) throws -> DNSGuardConfigSummary {
        guard let raw = try? decoder().decode(RawConfig.self, from: data) else {
            throw ParseError(message: "配置不是有效的 JSON")
        }
        guard let target = raw.targetDNS, !DNSList.normalize(target).isEmpty else {
            throw ParseError(message: "配置缺少 targetDNS")
        }
        return DNSGuardConfigSummary(targetDNS: target,
                                     connectedTakeoverEnabled: raw.connectedTakeover?.enabled ?? false)
    }

    public static func parseState(_ data: Data) throws -> DNSGuardState {
        guard let state = try? decoder().decode(DNSGuardState.self, from: data) else {
            throw ParseError(message: "状态文件不是有效的 JSON")
        }
        return state
    }

    /// 事件日志：每行一条，无法解码的行跳过。返回最后 `limit` 条（旧 → 新）。
    public static func parseEvents(_ data: Data, limit: Int) -> [DNSGuardEvent] {
        let decoder = decoder()
        let events = data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(DNSGuardEvent.self, from: Data(line))
        }
        return Array(events.suffix(max(0, limit)))
    }
}
