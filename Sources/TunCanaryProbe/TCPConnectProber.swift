import Foundation
import Network
import TunCanaryCore

/// 只能 resume 一次的门闩：连接状态回调与看门狗竞争时使用。
private final class TCPResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// 连接等待中最近一次的错误，看门狗超时时据此分类。
private final class TCPLastError: @unchecked Sendable {
    private let lock = NSLock()
    private var error: NWError?

    func set(_ value: NWError) {
        lock.lock()
        error = value
        lock.unlock()
    }

    func get() -> NWError? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

/// TCP 连接探测：只建立连接，不发送数据。
///
/// - 连接建立，或者端口拒绝连接（收到 RST），都说明路径可达，记为可达。
/// - 系统因“本地网络”隐私权限拒绝访问时，记为 `localNetworkDenied`，不计为失败。
/// - 超时记为超时；其余错误记为连接失败。
public enum TCPConnectProber {
    public static func probe(host: String, port: Int, timeout: TimeInterval) async -> RequestOutcome {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            return .failure(.connectionFailure, detail: "端口无效：\(port)")
        }
        let parameters = NWParameters.tcp
        if let options = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            options.connectionTimeout = Int(max(1, timeout.rounded(.up)))
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let gate = TCPResumeOnce()
        let lastError = TCPLastError()
        let queue = DispatchQueue(label: "tuncanary.tcp-probe")
        let start = DispatchTime.now().uptimeNanoseconds

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<RequestOutcome, Never>) in
                func finish(_ outcome: RequestOutcome) {
                    guard gate.claim() else { return }
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: outcome)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(.tcpAnswered(latency: elapsed(since: start), refused: false))
                    case .waiting(let error), .failed(let error):
                        if isLocalNetworkDenied(connection) {
                            finish(.failure(.localNetworkDenied, detail: "系统未授予本地网络权限"))
                        } else if case .posix(let code) = error, code == .ECONNREFUSED {
                            finish(.tcpAnswered(latency: elapsed(since: start), refused: true))
                        } else if case .failed = state {
                            finish(outcome(for: error))
                        } else if case .posix(let code) = error, code == .ETIMEDOUT {
                            finish(.failure(.timeout, detail: error.localizedDescription))
                        } else {
                            // 等待中的其他错误（如暂时无路由）：交给看门狗，超时前网络恢复仍可能连上。
                            lastError.set(error)
                        }
                    case .cancelled:
                        finish(.failure(.connectionFailure, detail: "已取消"))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + max(0, timeout)) {
                    if let error = lastError.get() {
                        finish(outcome(for: error, timedOut: true))
                    } else {
                        finish(.failure(.timeout, detail: "连接超时"))
                    }
                }
            }
        }, onCancel: { connection.cancel() })
    }

    private static func elapsed(since start: UInt64) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private static func isLocalNetworkDenied(_ connection: NWConnection) -> Bool {
        if #available(macOS 14.0, *) {
            return connection.currentPath?.unsatisfiedReason == .localNetworkDenied
        }
        return false
    }

    /// 连接失败的分类。等待超时且最后一个错误是无路由时，仍记为连接失败，附带原因。
    static func outcome(for error: NWError, timedOut: Bool = false) -> RequestOutcome {
        if case .posix(let code) = error, code == .ETIMEDOUT {
            return .failure(.timeout, detail: error.localizedDescription)
        }
        if timedOut, case .posix(let code) = error, code != .EHOSTUNREACH, code != .ENETUNREACH {
            return .failure(.timeout, detail: error.localizedDescription)
        }
        return .failure(.connectionFailure, detail: error.localizedDescription)
    }
}
