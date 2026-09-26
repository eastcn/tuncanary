import Foundation
import TunCanaryCore
import SystemConfiguration

/// SCDynamicStore 中用到的键。
public enum DynamicStoreKeys {
    public static let globalIPv4 = "State:/Network/Global/IPv4"
    public static let globalDNS = "State:/Network/Global/DNS"

    /// 服务的保存设置（含 `UserDefinedName`）。
    public static func serviceSetup(_ serviceID: String) -> String {
        "Setup:/Network/Service/\(serviceID)"
    }

    /// 服务的接口设置（含 `DeviceName`、`UserDefinedName`）。
    public static func serviceInterfaceSetup(_ serviceID: String) -> String {
        "Setup:/Network/Service/\(serviceID)/Interface"
    }

    /// 服务保存的 DNS（手动设置，或代理、VPN 客户端写入的值）。
    public static func serviceSetupDNS(_ serviceID: String) -> String {
        "Setup:/Network/Service/\(serviceID)/DNS"
    }

    /// 服务的 State DNS（通常为 DHCP 下发）。
    public static func serviceStateDNS(_ serviceID: String) -> String {
        "State:/Network/Service/\(serviceID)/DNS"
    }
}

/// 把 SCDynamicStore 的字典转换为模型（纯函数，便于用普通字典测试）。
public enum DynamicStoreMapping {
    /// 取 `ServerAddresses` 并规范化：去空白、去空字符串（DNS 被清空后保存值可能为 `[""]`）、去重。
    public static func serverAddresses(_ dictionary: [String: Any]?) -> [String] {
        guard let list = dictionary?["ServerAddresses"] as? [Any] else { return [] }
        return DNSList.normalize(list.compactMap { $0 as? String })
    }

    /// `State:/Network/Global/IPv4` 中的主服务 id 与主接口。
    public static func primary(globalIPv4: [String: Any]?) -> (serviceID: String, interfaceName: String?)? {
        guard let id = (globalIPv4?["PrimaryService"] as? String)?.trimmingCharacters(in: .whitespaces),
              !id.isEmpty else { return nil }
        let interface = (globalIPv4?["PrimaryInterface"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (id, interface)
    }

    /// 服务名：优先服务的 `UserDefinedName`，其次接口设置中的 `UserDefinedName`。
    public static func serviceName(serviceSetup: [String: Any]?, interfaceSetup: [String: Any]?) -> String? {
        for candidate in [serviceSetup?["UserDefinedName"], interfaceSetup?["UserDefinedName"]] {
            if let name = (candidate as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                return name
            }
        }
        return nil
    }

    /// 组装主网络服务。`globalIPv4` 缺失或没有 PrimaryService 时为 `.failed`。
    public static func primaryService(
        globalIPv4: [String: Any]?,
        serviceSetup: [String: Any]?,
        interfaceSetup: [String: Any]?,
        setupDNS: [String: Any]?,
        stateDNS: [String: Any]?
    ) -> Collected<PrimaryServiceInfo> {
        guard globalIPv4 != nil else {
            return .failed(reason: "没有主网络服务（\(DynamicStoreKeys.globalIPv4) 不存在）")
        }
        guard let (serviceID, primaryInterface) = primary(globalIPv4: globalIPv4) else {
            return .failed(reason: "\(DynamicStoreKeys.globalIPv4) 中没有 PrimaryService")
        }
        let deviceName = (interfaceSetup?["DeviceName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .collected(PrimaryServiceInfo(
            serviceID: serviceID,
            name: serviceName(serviceSetup: serviceSetup, interfaceSetup: interfaceSetup),
            interfaceName: primaryInterface ?? deviceName,
            savedDNS: serverAddresses(setupDNS),
            stateDNS: serverAddresses(stateDNS)
        ))
    }

    /// 全局生效 DNS。键不存在时为 `.failed`，由判定回退到解析器列表。
    public static func globalDNS(_ dictionary: [String: Any]?) -> Collected<[String]> {
        guard let dictionary else {
            return .failed(reason: "\(DynamicStoreKeys.globalDNS) 不存在")
        }
        return .collected(serverAddresses(dictionary))
    }
}

/// 读取主网络服务与全局 DNS（只读，每次调用新建一个 SCDynamicStore 会话）。
public struct DynamicStoreReader: Sendable {
    public struct Result: Sendable, Equatable {
        public var primaryService: Collected<PrimaryServiceInfo>
        public var globalDNS: Collected<[String]>

        public init(primaryService: Collected<PrimaryServiceInfo>, globalDNS: Collected<[String]>) {
            self.primaryService = primaryService
            self.globalDNS = globalDNS
        }
    }

    public init() {}

    public func read() -> Result {
        guard let store = SCDynamicStoreCreate(nil, "TunCanary.reader" as CFString, nil, nil) else {
            let reason = "无法连接 SCDynamicStore（\(String(cString: SCErrorString(SCError()))))"
            return Result(primaryService: .failed(reason: reason), globalDNS: .failed(reason: reason))
        }

        guard let first = copyMultiple(store, [DynamicStoreKeys.globalIPv4, DynamicStoreKeys.globalDNS]) else {
            let reason = "读取 SCDynamicStore 失败（\(String(cString: SCErrorString(SCError()))))"
            return Result(primaryService: .failed(reason: reason), globalDNS: .failed(reason: reason))
        }
        let globalIPv4 = first[DynamicStoreKeys.globalIPv4] as? [String: Any]
        let globalDNS = DynamicStoreMapping.globalDNS(first[DynamicStoreKeys.globalDNS] as? [String: Any])

        guard let (serviceID, _) = DynamicStoreMapping.primary(globalIPv4: globalIPv4) else {
            let service = DynamicStoreMapping.primaryService(
                globalIPv4: globalIPv4, serviceSetup: nil, interfaceSetup: nil, setupDNS: nil, stateDNS: nil)
            return Result(primaryService: service, globalDNS: globalDNS)
        }

        let keys = [
            DynamicStoreKeys.serviceSetup(serviceID),
            DynamicStoreKeys.serviceInterfaceSetup(serviceID),
            DynamicStoreKeys.serviceSetupDNS(serviceID),
            DynamicStoreKeys.serviceStateDNS(serviceID),
        ]
        guard let values = copyMultiple(store, keys) else {
            let reason = "读取 SCDynamicStore 失败（\(String(cString: SCErrorString(SCError()))))"
            return Result(primaryService: .failed(reason: reason), globalDNS: globalDNS)
        }
        let service = DynamicStoreMapping.primaryService(
            globalIPv4: globalIPv4,
            serviceSetup: values[keys[0]] as? [String: Any],
            interfaceSetup: values[keys[1]] as? [String: Any],
            setupDNS: values[keys[2]] as? [String: Any],
            stateDNS: values[keys[3]] as? [String: Any]
        )
        return Result(primaryService: service, globalDNS: globalDNS)
    }

    /// 一次 IPC 读取多个键；不存在的键不出现在结果中。读取失败时为 nil。
    private func copyMultiple(_ store: SCDynamicStore, _ keys: [String]) -> [String: Any]? {
        guard let values = SCDynamicStoreCopyMultiple(store, keys as CFArray, nil) else { return nil }
        return (values as NSDictionary) as? [String: Any] ?? [:]
    }
}
