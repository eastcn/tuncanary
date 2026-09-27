import Foundation

/// 本机状态判定引擎（纯函数）：代理 TUN、VPN 证据链、主网络 DNS 规则与代理 DNS。
public struct LocalEvaluator: Sendable {
    public let paths: KnownPaths
    public let adapters: [VPNAdapterConfig]
    /// 无法使用的适配器配置说明，显示在 VPN 卡的证据中。
    public let adapterProblems: [String]

    public init(paths: KnownPaths, adapters: [VPNAdapterConfig] = [], adapterProblems: [String] = []) {
        self.paths = paths
        self.adapters = adapters
        self.adapterProblems = adapterProblems
    }

    public init(paths: KnownPaths, adapterSet: VPNAdapterSet) {
        self.init(paths: paths, adapters: adapterSet.adapters, adapterProblems: adapterSet.problems)
    }

    public func evaluate(snapshot: LocalSnapshot, settings: AppSettings, inGracePeriod: Bool) -> LocalAssessment {
        let source = settings.proxySource
        let tun = analyzeTun(snapshot)
        let vpn = VPNAnalyzer(adapters: adapters, homeDirectory: paths.homeDirectory)
            .analyze(snapshot, proxyInterface: tun.interface?.name, fakeIPRange: tun.config?.fakeIPRange)
        let state: VPNConnectionState = inGracePeriod ? .switching : vpn.state
        let canary = analyzeCanary(snapshot, tun: tun)

        var cards = [
            makeTunCard(tun, source: source),
            makeVPNCard(vpn, state: state),
            makeDNSCard(snapshot, settings: settings, tun: tun, vpn: vpn, state: state, canary: canary),
            makeMihomoCard(snapshot, tun: tun, source: source),
        ]
        if let index = cards.firstIndex(where: { $0.kind == .primaryDNS }) {
            // AAAA 结果只作证据：不改变严重程度，不产生故障键。
            if let ipv6 = ipv6Evidence(snapshot, tun: tun) {
                cards[index].evidence.append(ipv6)
            }
            // 守护进程同样只作展示，与卡片的判定分开。
            cards[index].dnsGuard = DNSGuardSummary.make(snapshot.dnsGuard, settings: settings,
                                                         now: snapshot.collectedAt)
        }

        // 宽限期内不判定持续异常：黄、红降为灰，不产生故障键。
        if inGracePeriod {
            cards = cards.map { card in
                guard card.severity > .unknown else { return card }
                var capped = card
                capped.severity = .unknown
                capped.conclusion = "切换中：" + card.conclusion
                capped.hint = nil
                capped.faultKey = nil
                return capped
            }
        }

        let faults = cards.compactMap { card -> Fault? in
            guard let key = card.faultKey, card.severity.isAlerting else { return nil }
            return Fault(key: key, severity: card.severity, message: card.line, hint: card.hint)
        }

        var assessment = LocalAssessment(
            severity: Severity.worst(cards.map(\.severity)),
            cards: cards,
            faults: faults,
            primaryReason: "",
            tunState: tun.state,
            vpnState: state,
            isInGracePeriod: inGracePeriod,
            intranetProbeEnabled: state == .connected,
            primaryServiceName: snapshot.primaryService.value?.name,
            mihomoDNSPort: tun.config?.dnsListenPort,
            diagnosticNotes: diagnosticNotes(snapshot, tun: tun, vpn: vpn),
            learnableExpectedDNS: learnableExpectedDNS(snapshot, tun: tun, state: state, canary: canary),
            evaluatedAt: snapshot.collectedAt
        )
        if inGracePeriod {
            assessment.primaryReason = "网络切换中"
        } else if let top = assessment.reasons.first {
            assessment.primaryReason = top.text
        } else {
            assessment.primaryReason = "各项检查正常"
        }
        return assessment
    }

    // MARK: - 代理 TUN

    struct TunAnalysis {
        var state: TunState
        var config: ClashConfig?
        var interface: InterfaceInfo?
        var conclusion: String
        var evidence: [String]
    }

    func analyzeTun(_ snapshot: LocalSnapshot) -> TunAnalysis {
        let config: ClashConfig
        switch snapshot.clashConfig {
        case .notCollected:
            return TunAnalysis(state: .unknown, config: nil, interface: nil,
                               conclusion: "证据不足：未读取 Clash Verge 配置", evidence: [])
        case .failed(let reason):
            return TunAnalysis(state: .unknown, config: nil, interface: nil,
                               conclusion: "证据不足：Clash Verge 配置缺失或不可读",
                               evidence: ["原因：\(reason)"])
        case .collected(let value):
            config = value
        }
        if config.isManual { return analyzeManualTun(snapshot, config: config) }

        var evidence: [String] = []
        guard let configured = config.tunConfigured else {
            return TunAnalysis(state: .unknown, config: config, interface: nil,
                               conclusion: "证据不足：配置中未找到 TUN 开关",
                               evidence: ["verge.yaml 与 clash-verge.yaml 均未读到 TUN 开关"])
        }
        evidence.append(tunSwitchEvidence(config, configured: configured))
        if !configured {
            return TunAnalysis(state: .off, config: config, interface: nil, conclusion: "配置关闭", evidence: evidence)
        }

        guard let range = config.fakeIPRange else {
            evidence.append("配置缺少 dns.fake-ip-range")
            return TunAnalysis(state: .unknown, config: config, interface: nil,
                               conclusion: "证据不足：配置缺少 fake-ip 网段，无法识别 TUN 接口",
                               evidence: evidence)
        }

        var interfaceFound: Bool?
        var found: InterfaceInfo?
        if let interfaces = snapshot.interfaces.value {
            // 按 fake-ip 网段识别，设备名只作提示（同网段多个时优先同名）。
            let candidates = interfaces.filter { iface in
                iface.isTunnel && iface.isUp && iface.ipv4Addresses.contains(where: range.contains)
            }
            found = candidates.first { $0.name == config.tunDevice } ?? candidates.first
            interfaceFound = found != nil
            if let iface = found {
                let ip = iface.ipv4Addresses.first(where: range.contains).map { "\($0)" } ?? ""
                evidence.append("\(iface.name) 存在（\(ip)，位于 fake-ip 网段 \(range.normalized)）")
                if let device = config.tunDevice, device != iface.name {
                    evidence.append("配置设备名为 \(device)，实际接口为 \(iface.name)（设备名只作提示）")
                }
            } else {
                evidence.append("未找到 IPv4 位于 \(range.normalized) 的 UP utun")
            }
        } else {
            evidence.append("未采集网络接口")
        }

        let mihomo = snapshot.effectiveMihomoRunning
        switch mihomo {
        case .some(true): evidence.append("verge-mihomo 运行中")
        case .some(false): evidence.append("verge-mihomo 未运行")
        case .none: evidence.append("未采集 verge-mihomo 进程")
        }

        if interfaceFound == true, mihomo == true, let iface = found {
            return TunAnalysis(state: .running(interface: iface.name), config: config, interface: iface,
                               conclusion: "配置开启，\(iface.name) 存在", evidence: evidence)
        }
        if interfaceFound == false || mihomo == false {
            return TunAnalysis(state: .inactive, config: config, interface: found,
                               conclusion: "配置开启，但 TUN 未生效", evidence: evidence)
        }
        return TunAnalysis(state: .unknown, config: config, interface: found,
                           conclusion: "证据不足：未采集网络接口或进程", evidence: evidence)
    }

    /// 手动模式：不知道配置开关，TUN 是否运行只看 fake-ip 网段内的接口和（可选的）核心进程。
    func analyzeManualTun(_ snapshot: LocalSnapshot, config: ClashConfig) -> TunAnalysis {
        guard let range = config.fakeIPRange else {
            return TunAnalysis(state: .unknown, config: config, interface: nil,
                               conclusion: "证据不足：手动模式的 fake-ip 网段无效", evidence: [])
        }
        var evidence = ["手动模式：fake-ip 网段 \(range.normalized)"]
        guard let interfaces = snapshot.interfaces.value else {
            evidence.append("未采集网络接口")
            return TunAnalysis(state: .unknown, config: config, interface: nil,
                               conclusion: "证据不足：未采集网络接口", evidence: evidence)
        }
        let found = interfaces.first { iface in
            iface.isTunnel && iface.isUp && iface.ipv4Addresses.contains(where: range.contains)
        }
        var running: Bool?
        if let name = config.coreProcessName {
            running = snapshot.processes.value.map { list in list.contains { $0.executableName == name } }
            switch running {
            case .some(true): evidence.append("\(name) 运行中")
            case .some(false): evidence.append("\(name) 未运行")
            case .none: evidence.append("未采集 \(name) 进程")
            }
        }
        guard let iface = found else {
            evidence.append("未找到 IPv4 位于 \(range.normalized) 的 UP utun")
            return TunAnalysis(state: .off, config: config, interface: nil,
                               conclusion: "未发现 TUN 接口", evidence: evidence)
        }
        let ip = iface.ipv4Addresses.first(where: range.contains).map { "\($0)" } ?? ""
        evidence.insert("\(iface.name) 存在（\(ip)，位于 fake-ip 网段 \(range.normalized)）", at: 1)
        if running == false, let name = config.coreProcessName {
            return TunAnalysis(state: .inactive, config: config, interface: iface,
                               conclusion: "发现 TUN 接口，但 \(name) 未运行", evidence: evidence)
        }
        if config.coreProcessName != nil && running == nil {
            return TunAnalysis(state: .unknown, config: config, interface: iface,
                               conclusion: "证据不足：未采集进程", evidence: evidence)
        }
        return TunAnalysis(state: .running(interface: iface.name), config: config, interface: iface,
                           conclusion: "\(iface.name) 存在", evidence: evidence)
    }

    private func tunSwitchEvidence(_ config: ClashConfig, configured: Bool) -> String {
        var parts: [String] = []
        if let verge = config.vergeTunModeEnabled { parts.append("enable_tun_mode=\(verge)") }
        if let tun = config.tunEnabled { parts.append("tun.enable=\(tun)") }
        let detail = parts.isEmpty ? "" : "（\(parts.joined(separator: "，"))）"
        return "TUN：配置\(configured ? "开启" : "关闭")\(detail)"
    }

    func makeTunCard(_ tun: TunAnalysis, source: ProxySource) -> StatusCard {
        let severity: Severity
        var key: FaultKey?
        switch tun.state {
        case .running, .off:
            severity = .ok
        case .inactive:
            severity = .warning
            key = .tunInactive
        case .unknown:
            severity = .unknown
        }
        return StatusCard(kind: .proxyTun, title: source.tunLabel, severity: severity,
                          conclusion: tun.conclusion, evidence: tun.evidence, faultKey: key)
    }

    // MARK: - VPN

    func makeVPNCard(_ vpn: VPNAnalysis, state: VPNConnectionState) -> StatusCard {
        let severity: Severity
        let conclusion: String
        switch state {
        case .connected:
            severity = .ok
            conclusion = "已连接"
        case .disconnected:
            severity = .ok
            conclusion = vpn.adapters.isEmpty ? "未发现 VPN" : "已断开"
        case .switching:
            severity = .unknown
            conclusion = "切换中"
        case .unconfirmed:
            severity = .unknown
            conclusion = "状态未确认"
        }
        let problems = adapterProblems.map { "适配器配置无效：\($0)" }
        return StatusCard(kind: .vpn, title: vpn.title, severity: severity,
                          conclusion: conclusion, evidence: vpn.evidence + problems)
    }

    // MARK: - 系统解析 canary

    struct CanaryAnalysis {
        /// fake-ip 模式下返回的真实地址；无法判断时为 nil。
        var realAddresses: [IPv4]?
        var evidence: String?
    }

    func analyzeCanary(_ snapshot: LocalSnapshot, tun: TunAnalysis) -> CanaryAnalysis {
        let host = snapshot.canaryHost
        switch snapshot.canary {
        case .notTested:
            return CanaryAnalysis(realAddresses: nil, evidence: nil)
        case .failed(let reason):
            return CanaryAnalysis(realAddresses: nil, evidence: "系统解析 \(host) 失败：\(reason)")
        case .resolved(let addresses):
            let list = addresses.map(\.description).joined(separator: ", ")
            guard !addresses.isEmpty else {
                return CanaryAnalysis(realAddresses: nil, evidence: "系统解析 \(host) 无结果")
            }
            guard let config = tun.config, config.isFakeIPMode, let range = config.fakeIPRange else {
                return CanaryAnalysis(realAddresses: nil, evidence: "系统解析 \(host) 返回 \(list)")
            }
            let real = addresses.filter { !range.contains($0) }
            if real.isEmpty {
                return CanaryAnalysis(realAddresses: [], evidence: "系统解析 \(host) 返回 fake-ip \(list)")
            }
            let realList = real.map(\.description).joined(separator: ", ")
            // 探针域名被 fake-ip 过滤名单排除时，返回真实地址是正常的，不能据此判断绕过。
            switch FakeIPFilter.evaluate(host: host, filter: config.fakeIPFilter, mode: config.fakeIPFilterMode) {
            case .fakeIP:
                return CanaryAnalysis(realAddresses: real, evidence: "系统解析 \(host) 返回真实地址 \(realList)")
            case .excluded(let pattern):
                let reason = pattern.map { "（匹配 \($0)）" } ?? "（白名单模式下不在名单内）"
                return CanaryAnalysis(realAddresses: nil,
                                      evidence: "探针域名 \(host) 不分配 fake-ip\(reason)，无法检测绕过，请在设置中更换探针域名")
            case .uncertain(let entries):
                return CanaryAnalysis(realAddresses: nil,
                                      evidence: "系统解析 \(host) 返回真实地址 \(realList)，但 fake-ip 过滤名单含 \(entries.prefix(3).joined(separator: "、")) 等外部列表，无法确认是否绕过")
            }
        }
    }

    /// AAAA 查询的证据文本。只在 TUN 以 fake-ip 模式运行时给出；未查询时为 nil。
    func ipv6Evidence(_ snapshot: LocalSnapshot, tun: TunAnalysis) -> String? {
        guard tun.state.isRunning, let config = tun.config, config.isFakeIPMode else { return nil }
        let host = snapshot.canaryHost
        switch snapshot.canaryIPv6 {
        case .notTested:
            return nil
        case .failed(let reason):
            return "系统解析 \(host) 的 AAAA 记录失败：\(reason)"
        case .noRecord:
            return "系统解析 \(host) 无 AAAA 记录"
        case .resolved(let addresses):
            let list = addresses.map(\.description).joined(separator: ", ")
            let range6 = config.fakeIPRange6
            if let range6, addresses.allSatisfy(range6.contains) {
                return "系统解析 \(host) 的 AAAA 返回 fake-ip \(list)"
            }
            let real = addresses.filter { $0.isGlobalUnicast && !(range6?.contains($0) ?? false) }
            guard !real.isEmpty else {
                return "系统解析 \(host) 的 AAAA 返回 \(list)"
            }
            let realList = real.map(\.description).joined(separator: ", ")
            return "系统解析 \(host) 的 AAAA 返回真实 IPv6 地址 \(realList)（仅供参考：IPv6 流量可能未经过代理）"
        }
    }

    // MARK: - 主网络 DNS

    func makeDNSCard(
        _ snapshot: LocalSnapshot,
        settings: AppSettings,
        tun: TunAnalysis,
        vpn: VPNAnalysis,
        state: VPNConnectionState,
        canary: CanaryAnalysis
    ) -> StatusCard {
        guard case .collected(let service) = snapshot.primaryService else {
            let reason = snapshot.primaryService.failureReason.map { "（\($0)）" } ?? ""
            return StatusCard(kind: .primaryDNS, title: "主网络 DNS", severity: .unknown,
                              conclusion: "证据不足：未能读取主网络服务\(reason)")
        }

        let title = service.name.map { "\($0) DNS" } ?? "主网络 DNS"
        let label = service.name.map { "主网络 DNS（\($0)）" } ?? "主网络 DNS"
        let expected = settings.effectiveExpectedDNS
        let expectedText = expected.joined(separator: "、")
        // 字段可能在初始化后被改写，这里再规范化一次（`[""]` 视为空）。
        let saved = DNSList.normalize(service.savedDNS)
        let matchesExpected = !saved.isEmpty && DNSList.sameSet(saved, expected)

        var evidence = ["保存值：\(DNSList.display(saved))"]
        if let effective = snapshot.effectiveDNS, !DNSList.sameSet(effective, saved) {
            evidence.append("生效 DNS：\(DNSList.display(effective))")
        }

        func card(_ severity: Severity, _ conclusion: String, hint: String? = nil, key: FaultKey? = nil) -> StatusCard {
            StatusCard(kind: .primaryDNS, title: title, label: label, severity: severity,
                       conclusion: conclusion, hint: hint, evidence: evidence, faultKey: key)
        }

        switch state {
        case .switching:
            return card(.unknown, "切换中，暂不评估")
        case .unconfirmed:
            return card(.unknown, "VPN 状态未确认，暂不评估 DNS 规则")
        case .connected:
            switch settings.connectedDNSRule {
            case .notSet:
                return card(.ok, "VPN 已连接（不检查 DNS）")
            case .proxyTakeover:
                return proxyRuleCard(connected: true)
            case .vpnProvided:
                break
            }
            guard vpn.connectedReportsDNS else {
                return card(.ok, "VPN 已连接（未配置 VPN DNS，不检查）")
            }
            let provided = vpn.connectedDNS
            guard !provided.isEmpty else {
                return card(.unknown, "无法确认 VPN 下发的 DNS（状态文件不可读）")
            }
            evidence.append("VPN DNS：\(DNSList.display(provided))")
            // 有的客户端只把第一个 VPN DNS 写入保存值，所以按子集判断。
            if !saved.isEmpty && Set(saved).isSubset(of: Set(provided)) {
                return card(.ok, "DNS 为 VPN 下发的 DNS（连接期状态）", hint: "连接期状态；启用内网站点探测")
            }
            return card(.warning, "VPN 已连接，但 DNS 不是 VPN 下发的 DNS",
                        hint: "VPN DNS 未生效，内网域名可能无法解析", key: .dnsVPNMissing)
        case .disconnected:
            return proxyRuleCard(connected: false)
        }

        /// 断开期，以及连接期规则为“由代理接管”时：按断开期规则检查保存值，TUN 运行时还检查系统解析是否经过代理。
        func proxyRuleCard(connected: Bool) -> StatusCard {
            let rule = settings.disconnectedDNSRule
            let label = settings.proxySource.tunLabel
            // 接在中文后面：以英文开头时补一个空格，例如“重新开启 Clash TUN”“重新开启代理 TUN”。
            let tunName = (label.first?.isASCII == true ? " " : "") + label
            switch tun.state {
            case .running:
                let bypass = !(canary.realAddresses ?? []).isEmpty
                let matches: Bool
                switch rule {
                case .notSet: matches = true
                case .equals: matches = matchesExpected
                case .empty: matches = saved.isEmpty
                }
                if matches {
                    if let canaryEvidence = canary.evidence { evidence.append(canaryEvidence) }
                    if bypass {
                        return card(.critical, "系统 DNS 未经过代理",
                                    hint: "系统解析返回真实地址，DNS 查询绕过了代理。关闭并重新开启\(tunName)，再核对网络服务的 DNS 设置",
                                    key: .dnsBypassProxy)
                    }
                    let prefix = connected ? "VPN 已连接，由代理接管：" : ""
                    let hint = connected ? "连接期由代理接管；启用内网站点探测，内网站点失败时先检查代理能否解析内网域名" : nil
                    switch rule {
                    case .equals: return card(.ok, "\(prefix)DNS 为 \(expectedText)，符合预期", hint: hint)
                    case .empty: return card(.ok, "\(prefix)DNS 为空，符合预期", hint: hint)
                    case .notSet:
                        let text = canary.realAddresses == [] ? "系统解析返回 fake-ip，DNS 经过代理" : "未设置 DNS 规则"
                        return card(.ok, prefix + text, hint: hint)
                    }
                }
                // 红色卡片同时展示“保存值为空或残留”和“系统解析返回真实地址”。
                let known = Set(vpn.knownDNS)
                if saved.isEmpty {
                    evidence[0] = "保存值：空（DNS 已被清空）"
                } else if !known.isEmpty && Set(saved).isSubset(of: known) {
                    evidence[0] = "保存值：\(DNSList.display(saved))（\(connected ? "VPN 下发的 DNS" : "残留的 VPN DNS")）"
                } else if rule == .equals {
                    evidence[0] = "保存值：\(DNSList.display(saved))（与预期 \(expectedText) 不一致）"
                } else {
                    evidence[0] = "保存值：\(DNSList.display(saved))（应为空）"
                }
                if let canaryEvidence = canary.evidence { evidence.append(canaryEvidence) }
                let target = rule == .equals ? "为 \(expectedText)" : "（应为空）"
                if connected {
                    let fix = rule == .equals ? "把网络服务的 DNS 改为 \(expectedText)" : "清空网络服务保存的 DNS"
                    return card(.critical, "VPN 已连接、TUN 运行中，DNS 未由代理接管\(target)",
                                hint: "连接期 DNS 查询绕过了代理。\(fix)；VPN 客户端可能会再次改写", key: .dnsNotTakenOver)
                }
                return card(.critical, "VPN 已断开、TUN 运行中，DNS 未恢复\(target)",
                            hint: "等待 VPN 完全断开后，关闭并重新开启\(tunName)", key: .dnsNotRestored)
            case .off:
                // 连接期 TUN 关闭时由 VPN 下发 DNS，不检查残留。
                if connected {
                    return card(.ok, "VPN 已连接、TUN 已关闭，不检查 DNS")
                }
                let residual = rule == .equals && settings.residualDNSWarning ? expected.filter { saved.contains($0) } : []
                if !residual.isEmpty {
                    return card(.warning, "TUN 已关闭，但 DNS 仍含 \(residual.joined(separator: "、"))",
                                hint: "可能是残留配置", key: .dnsResidual)
                }
                return card(.ok, saved.isEmpty ? "TUN 已关闭，DNS 未手动设置" : "TUN 已关闭，DNS 为 \(DNSList.display(saved))")
            case .inactive, .unknown:
                switch rule {
                case .notSet:
                    return card(.ok, "未设置 DNS 规则")
                case .equals where matchesExpected:
                    return card(.ok, "DNS 为 \(expectedText)，符合预期")
                case .empty where saved.isEmpty:
                    return card(.ok, "DNS 为空，符合预期")
                default:
                    let reason = tun.state == .inactive ? "\(label) 未生效" : "\(label) 状态未确认"
                    return card(.unknown, "\(reason)，暂不评估 DNS")
                }
            }
        }
    }

    /// 可以作为“断开后预期 DNS”的当前保存值：VPN 已断开、TUN 运行，且系统解析确认经过代理。
    func learnableExpectedDNS(_ snapshot: LocalSnapshot, tun: TunAnalysis, state: VPNConnectionState,
                              canary: CanaryAnalysis) -> [String]? {
        guard state == .disconnected, tun.state.isRunning, canary.realAddresses == [],
              let saved = snapshot.primaryService.value.map({ DNSList.normalize($0.savedDNS) }),
              !saved.isEmpty else { return nil }
        return saved
    }

    // MARK: - 代理 DNS

    func makeMihomoCard(_ snapshot: LocalSnapshot, tun: TunAnalysis, source: ProxySource) -> StatusCard {
        let title = source.dnsLabel
        switch snapshot.mihomoDNS {
        case .success(let port, let latency, let answers):
            var evidence: [String] = []
            if answers.isEmpty {
                evidence.append("应答中没有 A 记录")
            } else {
                let list = answers.map(\.description).joined(separator: ", ")
                if let range = tun.config?.fakeIPRange, answers.allSatisfy(range.contains) {
                    evidence.append("应答 \(list)（fake-ip，属正常）")
                } else {
                    evidence.append("应答 \(list)")
                }
            }
            return StatusCard(kind: .proxyDNS, title: title, severity: .ok,
                              conclusion: "\(port) 端口响应 \(LatencyFormat.milliseconds(latency))",
                              evidence: evidence)
        case .noResponse(let port):
            switch tun.state {
            case .running:
                return StatusCard(kind: .proxyDNS, title: title, severity: .warning,
                                  conclusion: "\(port) 端口无响应",
                                  evidence: ["向 \(PulseConstants.mihomoDNSHost):\(port) 查询超时或被拒绝"],
                                  faultKey: .mihomoNoResponse)
            case .off:
                return StatusCard(kind: .proxyDNS, title: title, severity: .ok,
                                  conclusion: "不适用（TUN 已关闭）",
                                  evidence: ["\(port) 端口无响应"])
            case .inactive, .unknown:
                return StatusCard(kind: .proxyDNS, title: title, severity: .unknown,
                                  conclusion: "\(port) 端口无响应（TUN 未生效或状态未确认）")
            }
        case .notApplicable, .notCollected:
            if tun.state == .off {
                return StatusCard(kind: .proxyDNS, title: title, severity: .ok, conclusion: "不适用（TUN 已关闭）")
            }
            if tun.config?.isManual == true && tun.config?.dnsListenPort == nil {
                return StatusCard(kind: .proxyDNS, title: title, severity: .ok, conclusion: "未填写端口，不检测")
            }
            if tun.config != nil && tun.config?.dnsListenPort == nil {
                return StatusCard(kind: .proxyDNS, title: title, severity: .unknown,
                                  conclusion: "证据不足：配置缺少 dns.listen 端口")
            }
            return StatusCard(kind: .proxyDNS, title: title, severity: .unknown, conclusion: "未检测")
        }
    }

    // MARK: - 诊断信息

    func diagnosticNotes(_ snapshot: LocalSnapshot, tun: TunAnalysis, vpn: VPNAnalysis) -> [String] {
        var notes: [String] = []
        if let interfaces = snapshot.interfaces.value {
            let involved = vpn.claimedTunnels.union(vpn.unrecognizedTunnels)
            let others = interfaces.filter { iface in
                iface.isTunnel && !iface.ipv4Addresses.isEmpty
                    && iface.name != tun.interface?.name && !involved.contains(iface.name)
            }
            for iface in others {
                let ips = iface.ipv4Addresses.map(\.description).joined(separator: ", ")
                let tailscale = iface.ipv4Addresses.contains(where: IPv4CIDR.tailscale.contains) ? "，疑似 Tailscale" : ""
                notes.append("其他隧道 \(iface.name)（\(ips)\(tailscale)），不参与判定")
            }
        }
        if let resolvers = snapshot.resolvers.value {
            let primaryInterface = snapshot.primaryService.value?.interfaceName
            let others = resolvers.filter { $0.isScoped && $0.interfaceName != nil && $0.interfaceName != primaryInterface }
            for resolver in others {
                let servers = DNSList.display(resolver.nameservers)
                notes.append("其他解析器 \(resolver.interfaceName ?? "?")（\(servers)），不参与判定")
            }
        }
        return notes
    }
}

/// 延迟格式化。
public enum LatencyFormat {
    /// 秒 → “35 ms”。
    public static func milliseconds(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded())) ms"
    }
}
