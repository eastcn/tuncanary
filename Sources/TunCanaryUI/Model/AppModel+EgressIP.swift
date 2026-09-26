import Foundation
import TunCanaryCore

extension AppModel {
    public func checkEgressIP() {
        guard !isCheckingEgress, let checker = egressChecker else { return }
        egressGeneration += 1
        let generation = egressGeneration
        isCheckingEgress = true
        egressResults = []
        egressTask = Task { [weak self] in
            let results = await checker.check(targets: settings.effectiveEgressTargets)
            guard !Task.isCancelled, let self, self.egressGeneration == generation else { return }
            self.egressResults = results
            self.isCheckingEgress = false
            self.egressTask = nil
        }
    }

    public func cancelEgressIP() {
        egressGeneration += 1
        egressTask?.cancel()
        egressTask = nil
        isCheckingEgress = false
        egressResults = []
    }
}
