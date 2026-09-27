import Foundation

/// 单次探测请求的结果类别。不能把各类失败统一写成“网络不通”。
public enum ProbeCategory: String, Sendable, Codable, CaseIterable {
    /// 2xx、3xx。
    case reachable
    /// 4xx：目标有响应但访问受限。
    case restricted
    /// 5xx。
    case serverError
    case tlsError
    case timeout
    case dnsFailure
    /// 拒绝、重置、无路由等。
    case connectionFailure
    /// 系统拒绝本应用访问本地网络（macOS“本地网络”隐私权限）。无法判断目标是否可达。
    case localNetworkDenied

    /// 是否计为告警失败：超时、DNS 失败、连接失败、TLS 错误和 5xx。4xx 和本地网络权限被拒不计。
    public var countsAsFailure: Bool {
        switch self {
        case .reachable, .restricted, .localNetworkDenied: return false
        case .serverError, .tlsError, .timeout, .dnsFailure, .connectionFailure: return true
        }
    }

    public var displayName: String {
        switch self {
        case .reachable: return "可达"
        case .restricted: return "有响应（访问受限）"
        case .serverError: return "服务器错误（5xx）"
        case .tlsError: return "TLS 错误"
        case .timeout: return "超时"
        case .dnsFailure: return "DNS 解析失败"
        case .connectionFailure: return "连接失败"
        case .localNetworkDenied: return "未获得本地网络权限"
        }
    }

    /// 历史记录中的短名。
    public var shortName: String {
        switch self {
        case .reachable: return "可达"
        case .restricted: return "受限"
        case .serverError: return "5xx"
        case .tlsError: return "TLS"
        case .timeout: return "超时"
        case .dnsFailure: return "DNS"
        case .connectionFailure: return "连接"
        case .localNetworkDenied: return "权限"
        }
    }

    /// 按 HTTP 状态码分类：<400 可达，4xx 访问受限，其余为服务器错误。
    public init(httpStatus: Int) {
        switch httpStatus {
        case ..<400: self = .reachable
        case 400..<500: self = .restricted
        default: self = .serverError
        }
    }

    /// 按 URLError 分类（探测器可直接使用）。
    public init(urlErrorCode code: URLError.Code) {
        switch code {
        case .timedOut:
            self = .timeout
        case .cannotFindHost, .dnsLookupFailed:
            self = .dnsFailure
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            self = .tlsError
        default:
            self = .connectionFailure
        }
    }
}
