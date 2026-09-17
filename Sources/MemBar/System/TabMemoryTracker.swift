import Foundation

/// Per-tab memory attribution derived from burst pairing.
struct TabAttribution: Equatable {
    let tabID: Int
    var renderers: [ChromeHelper]
    var isShared: Bool = false

    var totalBytes: UInt64 {
        renderers.reduce(0) { $0 + $1.footprintBytes }
    }
    var totalMB: Double { Double(totalBytes) / 1_000_000 }
    var processCount: Int { renderers.count }
    var embedCount: Int { max(0, renderers.count - 1) }
    var mainFrameBytes: UInt64 { renderers.first?.footprintBytes ?? 0 }
    var embedBytes: UInt64 { renderers.dropFirst().reduce(0) { $0 + $1.footprintBytes } }
}

/// Tracks renderer lifecycle and pairs renderer birth bursts to tabs.
final class TabMemoryTracker {
    private var knownRendererPIDs: Set<pid_t> = []
    private var knownTabs: [Int: ChromeTab] = [:]
    private(set) var attributions: [Int: TabAttribution] = [:]

    /// Called on each 3s tick with current renderers and fresh tab list.
    func update(renderers: [ChromeHelper], currentTabs: [ChromeTab]?) {
        let currentPIDs = Set(renderers.map { $0.pid })
        let rendererMap = Dictionary(renderers.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        // 1. Update footprint of existing attributions and purge dead PIDs
        for (tabID, attr) in attributions {
            var updatedRenderers: [ChromeHelper] = []
            for r in attr.renderers {
                if let live = rendererMap[r.pid] {
                    updatedRenderers.append(live)
                }
            }
            if updatedRenderers.isEmpty {
                attributions.removeValue(forKey: tabID)
            } else {
                attributions[tabID]?.renderers = updatedRenderers
            }
        }

        // 2. Identify new renderer births
        guard let currentTabs else { return }

        let newPIDs = currentPIDs.subtracting(knownRendererPIDs)
        knownRendererPIDs = currentPIDs

        guard !newPIDs.isEmpty else {
            updateKnownTabs(currentTabs)
            return
        }

        let births = renderers
            .filter { newPIDs.contains($0.pid) }
            .sorted { ($0.clientID ?? 0) < ($1.clientID ?? 0) }

        // 3. Diff tabs against previous snapshot
        let currentTabIDs = Set(currentTabs.map { $0.id })
        let newTabs = currentTabs.filter { knownTabs[$0.id] == nil }
        let navigated = currentTabs.filter {
            if let prev = knownTabs[$0.id], prev.host != $0.host { return true }
            return false
        }

        // 4. Burst pairing rule (Phase 3.1)
        if newTabs.count == 1 && navigated.isEmpty {
            // Exactly one tab opened -> attribute all births to it
            let targetID = newTabs[0].id
            attributions[targetID] = TabAttribution(tabID: targetID, renderers: births)
        } else if newTabs.isEmpty && navigated.count == 1 {
            // Exactly one tab navigated -> replace with new births
            let targetID = navigated[0].id
            attributions[targetID] = TabAttribution(tabID: targetID, renderers: births)
        } else {
            // Multiple tabs opened or navigated simultaneously (e.g. session restore).
            // Do not guess: leave them unmeasured.
        }

        // 5. Detect shared sites
        var hostTabCounts: [String: Int] = [:]
        for tab in currentTabs {
            hostTabCounts[tab.host, default: 0] += 1
        }
        for (tabID, _) in attributions {
            if let tab = currentTabs.first(where: { $0.id == tabID }),
               let count = hostTabCounts[tab.host], count > 1 {
                attributions[tabID]?.isShared = true
            } else {
                attributions[tabID]?.isShared = false
            }
        }

        // Purge attributions for tabs that closed
        attributions = attributions.filter { currentTabIDs.contains($0.key) }
        updateKnownTabs(currentTabs)
    }

    private func updateKnownTabs(_ tabs: [ChromeTab]) {
        knownTabs = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func attribution(for tabID: Int) -> TabAttribution? {
        attributions[tabID]
    }
}
