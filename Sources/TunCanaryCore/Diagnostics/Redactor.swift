import Foundation

/// 脱敏：内网 IP 只保留首段；去掉主目录路径；不输出内网站点 URL。
/// 诊断摘要、命令行输出和通知正文都经过它。
public struct Redactor: Sendable {
    public var homeDirectory: String?
    public var intranetURL: URL?
    public var siteURLs: [URL]

    /// 内网站点 URL 与主机名的替代文本。
    public static let intranetPlaceholder = "[内网站点]"
    /// 检测站点 URL 与主机名的替代文本。
    public static let sitePlaceholder = "[检测站点]"

    public init(homeDirectory: String? = nil, intranetURL: URL? = nil, siteURLs: [URL] = []) {
        self.homeDirectory = homeDirectory
        self.intranetURL = intranetURL
        self.siteURLs = siteURLs
    }

    public func redact(_ text: String) -> String {
        var result = text
        result = redactIntranet(result)
        // 先做私网 IP 脱敏，避免数字主机名先被替换后 IP 规则失效。
        result = redactPrivateIPv4(result)
        result = redactSites(result)
        result = redactHome(result)
        return result
    }

    /// 检测站点：完整 URL 全文替换；主机名只替换自定义站点的，并按主机名边界匹配。
    /// 内置站点的主机名是公开域名（如系统解析证据中的 www.google.com），不替换；
    /// 纯数字、IP 形式和少于 4 个字符的主机名容易误伤正文，也不替换。
    private func redactSites(_ text: String) -> String {
        var result = text
        let builtinHosts = Set(SiteCatalog.templates.compactMap { $0.url.host?.lowercased() })
        for url in siteURLs {
            // 网络错误可能带上请求 URL；自定义站点也可能是内部服务。
            result = result.replacingOccurrences(of: url.absoluteString, with: Redactor.sitePlaceholder,
                                                 options: [.caseInsensitive])
            guard let host = url.host, Redactor.isRedactableHost(host),
                  !builtinHosts.contains(host.lowercased()) else { continue }
            let pattern = "(?<![A-Za-z0-9.-])" + NSRegularExpression.escapedPattern(for: host)
                + "(?![A-Za-z0-9-])(?!\\.[A-Za-z0-9-])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: Redactor.sitePlaceholder))
        }
        return result
    }

    /// 主机名至少 4 个字符，且不是纯数字或 IP 形式。
    static func isRedactableHost(_ host: String) -> Bool {
        guard host.count >= 4, !host.contains(":") else { return false }
        return !host.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
    }

    private func redactIntranet(_ text: String) -> String {
        guard let url = intranetURL else { return text }
        var result = text
        var candidates = [url.absoluteString]
        if url.absoluteString.hasSuffix("/") { candidates.append(String(url.absoluteString.dropLast())) }
        if let host = url.host, !host.isEmpty { candidates.append(host) }
        for candidate in candidates where !candidate.isEmpty {
            result = result.replacingOccurrences(of: candidate, with: Redactor.intranetPlaceholder,
                                                 options: [.caseInsensitive])
        }
        return result
    }

    private func redactHome(_ text: String) -> String {
        var result = text
        if let home = homeDirectory, home.count > 1 {
            result = result.replacingOccurrences(of: home, with: "~")
        }
        // 兜底：任何 /Users/<name> 都替换为 ~
        return Redactor.usersPattern.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "~")
    }

    private func redactPrivateIPv4(_ text: String) -> String {
        let nsText = text as NSString
        let matches = Redactor.ipv4Pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let candidate = nsText.substring(with: match.range)
            guard let ip = IPv4(candidate), ip.isPrivateForRedaction else { continue }
            mutable.replaceCharacters(in: match.range, with: "\(ip.octets[0]).x.x.x")
        }
        return mutable as String
    }

    private static let usersPattern = try! NSRegularExpression(pattern: "/Users/[^/\\s:：，,）)\"']+")
    private static let ipv4Pattern = try! NSRegularExpression(
        pattern: "(?<![0-9.])[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}(?![0-9]|\\.[0-9])")
}
