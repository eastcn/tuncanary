import Foundation
import TunCanaryCore

/// 显式查询目标已回显的 IP。绝不把查询服务自身看到的出口当成目标出口。
public struct EgressGeoClient: EgressGeoLookingUp, Sendable {
    private let configurationFactory: @Sendable () -> URLSessionConfiguration
    public init(configurationFactory: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.configurationFactory = configurationFactory
    }
    public func lookup(ip: String) async -> EgressGeoLookup {
        guard !Task.isCancelled,
              let encoded = ip.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://ipwho.is/\(encoded)?fields=ip,success,country_code,region,city,connection.isp") else { return EgressGeoLookup() }
        guard EgressIPChecker.normalizedIP(ip) == ip else { return EgressGeoLookup() }
        let response = await EgressRequest().run(url: url, configuration: configurationFactory(), timeout: 8)
        let body: Data
        switch response {
        case .body(let data): body = data
        case .rateLimited(let date): return EgressGeoLookup(retryAfter: date ?? Date().addingTimeInterval(86400))
        default: return EgressGeoLookup()
        }
        guard !Task.isCancelled else { return EgressGeoLookup() }
        guard body.count <= 16 * 1024,
              let data = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              data["success"] as? Bool == true,
              let returned = data["ip"] as? String, EgressIPChecker.normalizedIP(returned) == ip,
              let country = data["country_code"] as? String,
              EgressRegions.all.contains(country.uppercased()) else { return EgressGeoLookup() }
        func clean(_ value: Any?) -> String {
            String((value as? String ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(100))
        }
        let connection = data["connection"] as? [String: Any]
        return EgressGeoLookup(geo: EgressGeo(ip: ip, countryCode: country.uppercased(), region: clean(data["region"]),
                                            city: clean(data["city"]), isp: clean(connection?["isp"]), checkedAt: Date()))
    }
}
