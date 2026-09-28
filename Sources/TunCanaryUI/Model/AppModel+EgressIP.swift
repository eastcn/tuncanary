import Foundation
import TunCanaryCore

extension AppModel {
    /// 手动检测立即触发并入库，不改变自动采样周期；两者都遵守服务端限流。
    public func checkEgressIP(automatic: Bool = false) {
        guard !isCheckingEgress else { return }
        guard !automatic || settings.egressMonitoring.automatic else { return }
        guard !egressPaused else {
            if !automatic { egressCheckFeedback = "检测暂时暂停：系统休眠或网络切换恢复中，请稍后再试。" }
            return
        }
        guard let checker = egressChecker else {
            if !automatic { egressCheckFeedback = "出口检测服务不可用。" }
            return
        }
        let date = now()
        let interval = settings.egressMonitoring.effectiveInterval
        let eligible = settings.effectiveEgressTargets.filter {
            // 旧淘宝非公开接口保留手动能力，自动检测使用字节目标。
            (!automatic || $0 != .taobao) && (automatic
                ? egressState.isEligible($0, at: date, interval: interval)
                : egressState.isManuallyEligible($0, at: date))
        }
        // 后台每次调度只取一个目标，错开请求；手动仍可检测全部到期目标。
        let targets = automatic ? Array(eligible.prefix(1)) : eligible
        guard !targets.isEmpty else {
            if !automatic {
                let waiting = settings.effectiveEgressTargets.filter { egressState.controls[$0.rawValue]?.suspended != true }
                if let next = waiting.compactMap({ egressState.manualCooldownUntil($0) }).min() {
                    let time = next.formatted(date: .omitted, time: .standard)
                    egressCheckFeedback = "目标仍在服务端限流冷却中，下次可检测：\(time)。"
                } else {
                    egressCheckFeedback = "所有目标已暂停，请展开目标详情后点击“恢复”。"
                }
            }
            return
        }
        egressCheckFeedback = automatic ? nil : "正在检测 \(targets.count) 个目标…"
        egressGeneration += 1
        let generation = egressGeneration
        let configuration = settings.egressMonitoring
        isCheckingEgress = true
        egressResults.removeAll { targets.contains($0.target) }
        for target in targets { egressState.begin(target, at: date, automatic: automatic) }
        egressTask = Task { [weak self] in
            guard let self else { return }
            await self.persistEgressState()
            guard !Task.isCancelled, self.egressGeneration == generation else { return }
            let results = await checker.check(targets: targets)
            guard !Task.isCancelled, self.egressGeneration == generation else { return }
            var alerts: [EgressAlert] = []
            // 同轮相同 IP 只查询一次，查询服务失败按 IP 冷却，429 对整个服务冷却。
            for result in results where targets.contains(result.target) {
                var geo: EgressGeo?
                if result.isSuccess, let ip = result.ip {
                    geo = self.egressState.geoCache[ip]
                    if geo?.isFresh(at: result.checkedAt) != true,
                       (self.egressState.geoNextAttempt[ip] ?? .distantPast) <= self.now(),
                       (self.egressState.geoServiceNextAttempt ?? .distantPast) <= self.now(),
                       let client = self.egressGeoClient {
                        let lookup = await client.lookup(ip: ip)
                        guard !Task.isCancelled, self.egressGeneration == generation else { return }
                        if let found = lookup.geo, found.ip == ip {
                            geo = found
                            self.egressState.geoCache[ip] = found
                            self.egressState.geoNextAttempt[ip] = nil
                        } else {
                            self.egressState.geoNextAttempt[ip] = self.now().addingTimeInterval(3600)
                        }
                        if let retry = lookup.retryAfter { self.egressState.geoServiceNextAttempt = retry }
                    }
                }
                alerts += self.egressState.record(EgressObservation(result: result, geo: geo), settings: configuration, automatic: automatic)
                self.egressResults.removeAll { $0.target == result.target }
                self.egressResults.append(result)
            }
            await self.persistEgressState()
            guard !Task.isCancelled, self.egressGeneration == generation else { return }
            self.isCheckingEgress = false
            self.egressTask = nil
            if !automatic {
                let succeeded = results.filter { targets.contains($0.target) && $0.isSuccess }.count
                self.egressCheckFeedback = "检测完成：\(succeeded) 个成功，\(targets.count - succeeded) 个失败。展开目标可查看详情。"
            }
            if self.settings.notificationsEnabled {
                for alert in alerts {
                    guard !Task.isCancelled, self.egressGeneration == generation else { return }
                    await self.deliverEgressAlert(alert)
                }
            }
        }
    }

    public func cancelEgressIP() {
        if isCheckingEgress, egressCheckFeedback?.hasPrefix("正在检测") == true {
            egressCheckFeedback = "检测已取消。"
        }
        egressGeneration += 1
        egressTask?.cancel()
        egressTask = nil
        isCheckingEgress = false
        egressResults = []
    }

    public func pauseEgressMonitoring(_ paused: Bool) {
        egressPaused = paused
        if paused { cancelEgressIP() }
    }

    public func egressSettingsDidChange() {
        cancelEgressIP()
        egressCheckFeedback = nil
        // 正常目标立即使用新间隔；失败退避和服务端冷却保留。
        for (key, var control) in egressState.controls where control.failures == 0 {
            if let latest = egressState.history.last(where: { $0.result.target.rawValue == key && $0.result.isSuccess }) {
                control.nextAttempt = latest.result.checkedAt.addingTimeInterval(settings.egressMonitoring.effectiveInterval)
                egressState.controls[key] = control
            }
        }
        Task { [weak self] in await self?.persistEgressState() }
        // 不保留旧规则的连续次数；用户调整地域不是一次网络恢复。
        for (key, var state) in egressState.regionAlerts {
            let rule = settings.egressMonitoring.allowedRegions[key] ?? []
            if rule != state.rule {
                state = EgressRegionAlertState(); state.rule = rule
                egressState.regionAlerts[key] = state
            }
        }
    }

    public func resumeEgressTarget(_ target: EgressIPTarget) {
        egressState.resume(target)
        checkEgressIP()
    }

    public func egressSummary(_ target: EgressIPTarget) -> EgressStabilitySummary {
        egressState.summary(for: target, at: now(), interval: settings.egressMonitoring.effectiveInterval)
    }

    public func maintainEgressHistory() async {
        let date = now()
        guard date.timeIntervalSince(egressLastPrunedAt ?? .distantPast) >= 3600 else { return }
        egressLastPrunedAt = date
        egressState.prune(at: date)
        await persistEgressState()
    }

    private func persistEgressState() async {
        guard let store = egressHistoryStore else { return }
        let state = egressState
        egressPersistenceRevision += 1
        let revision = egressPersistenceRevision
        let success = await Task.detached(priority: .utility) { store.save(state, revision: revision) }.value
        guard revision == egressPersistenceRevision else { return }
        egressPersistenceError = success ? nil : "出口历史写入失败，本轮仅保存在内存"
    }
}
