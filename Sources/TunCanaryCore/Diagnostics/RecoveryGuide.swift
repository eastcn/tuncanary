import Foundation

/// 手动恢复步骤（随应用提供，不依赖工作目录中的文件）。
public enum RecoveryGuide {
    public static let title = "手动恢复步骤"

    /// 5 步恢复说明。`serviceName` 为主网络服务名（如 “Wi-Fi”），未知时显示占位；
    /// `expectedDNS` 为空时不写具体地址。
    public static func steps(serviceName: String?, expectedDNS: [String] = [],
                             proxy: ProxySource = ProxySource()) -> [String] {
        let dns = DNSList.normalize(expectedDNS)
        let service: String
        if let name = serviceName, !name.isEmpty {
            service = name.contains(" ") ? "\"\(name)\"" : name
        } else {
            service = "<服务名>"
        }
        let check = dns.isEmpty
            ? "核对 DNS 是否为你期望的值"
            : "核对 DNS 是否恢复为预期值（\(dns.joined(separator: "、"))）"
        return [
            "确认 VPN 已完全断开：VPN 进程已退出，VPN 隧道已消失。",
            proxy.client == .manual
                ? "在代理客户端中关闭 TUN，等待数秒后重新开启。"
                : "在 \(proxy.clientLabel) 中关闭 TUN，等待数秒后重新开启。",
            "运行 networksetup -getdnsservers \(service)，\(check)。",
            "仍未恢复时，在“系统设置 → 网络 → 对应服务 → 详细信息 → DNS”中手动设置。",
            "在弹窗中点“立即复测”，确认主网络 DNS 卡恢复正常、系统解析返回 fake-ip。",
        ]
    }

    /// 带编号的纯文本。
    public static func render(serviceName: String?, expectedDNS: [String] = [],
                              proxy: ProxySource = ProxySource()) -> String {
        let lines = steps(serviceName: serviceName, expectedDNS: expectedDNS, proxy: proxy)
            .enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
        return ([title] + lines).joined(separator: "\n")
    }
}
