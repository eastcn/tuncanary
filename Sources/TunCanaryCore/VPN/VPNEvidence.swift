import Foundation

/// VPN 连接状态。
public enum VPNConnectionState: String, Sendable, Equatable, Codable {
    case connected
    case disconnected
    /// 处于宽限期内。
    case switching
    /// 证据不足或互相矛盾。
    case unconfirmed

    public var displayName: String {
        switch self {
        case .connected: return "已连接"
        case .disconnected: return "已断开"
        case .switching: return "切换中"
        case .unconfirmed: return "未确认"
        }
    }
}

/// 一个 VPN 证据信号：真、假或未知。
public struct VPNSignal: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        /// 必要条件，例如进程存在。
        case required
        /// 佐证，至少一个为真才算连接，例如隧道、路由。
        case supporting
        /// 只作参考，与结论相反时改判未确认，例如状态文件。值表示“声称已连接”。
        case advisory
    }

    public var role: Role
    public var value: Bool?

    public init(_ role: Role, _ value: Bool?) {
        self.role = role
        self.value = value
    }
}

/// 证据合并规则（三值逻辑）：
/// - 已连接：全部 required 为真，且至少一个 supporting 为真。
/// - 已断开：全部 required 与 supporting 为假。
/// - 其余为未确认；advisory 与上述结论相反时也改判未确认。
public enum VPNEvidenceMerger {
    /// 判为未确认的原因。
    public enum Reason: Sendable, Equatable {
        case requiredUnknown
        case supportingUnknown
        case requiredWithoutSupport
        case supportWithoutRequired
        /// advisory 信号与结论相反；参数为 advisory 声称的连接状态。
        case advisoryContradicts(claimsConnected: Bool)
    }

    public static func merge(_ signals: [VPNSignal]) -> (state: VPNConnectionState, reason: Reason?) {
        let required = signals.filter { $0.role == .required }.map(\.value)
        let supporting = signals.filter { $0.role == .supporting }.map(\.value)

        var state: VPNConnectionState
        var reason: Reason?
        if required.allSatisfy({ $0 == true }) && supporting.contains(true) {
            state = .connected
        } else if required.allSatisfy({ $0 == false }) && supporting.allSatisfy({ $0 == false }) {
            state = .disconnected
        } else {
            state = .unconfirmed
            if required.contains(where: { $0 == nil }) {
                reason = .requiredUnknown
            } else if supporting.contains(where: { $0 == nil }) {
                reason = .supportingUnknown
            } else if required.allSatisfy({ $0 == true }) {
                reason = .requiredWithoutSupport
            } else {
                reason = .supportWithoutRequired
            }
        }
        for signal in signals where signal.role == .advisory {
            guard let claims = signal.value else { continue }
            if (state == .connected && !claims) || (state == .disconnected && claims) {
                state = .unconfirmed
                reason = .advisoryContradicts(claimsConnected: claims)
            }
        }
        return (state, reason)
    }
}
