import Foundation

/// Owns every live data source (kernel memory stats, the pressure dispatch
/// source, process enumeration, Chrome) and publishes what the views need.
final class SystemMonitor: ObservableObject {
    @Published private(set) var memory: MemorySnapshot?
    @Published private(set) var pressureLevel: PressureLevel = .low
    @Published private(set) var topApps: [RunningAppUsage] = []
    @Published private(set) var leftoverBackgroundGroups: [LeftoverBackgroundGroup] = []
    @Published private(set) var pressureSamples: [Double] = []
    @Published private(set) var chromeTabs: [ChromeTab] = []
    @Published private(set) var chromeIsRunning = false
    @Published private(set) var chromeDistribution: ChromeDistribution?
    @Published private(set) var tabAttributions: [Int: TabAttribution] = [:]

    private let pressureMonitor = PressureMonitor()
    private let appsMonitor = RunningAppsMonitor()
    private let chromeInventory = ChromeProcessInventory()
    private let tabTracker = TabMemoryTracker()
    private let workQueue = DispatchQueue(label: "app.pulse.system-monitor", qos: .utility)

    private var fastTimer: Timer?
    private var historyTimer: Timer?
    private var chromeTimer: Timer?
    private var chromeAlertTimer: Timer?
    private var vmTimer: Timer?
    private var chromeIdleSince: [String: Date] = [:]
    private var isStarted = false
    private(set) var isPaletteVisible: Bool = false

    var chromeMemoryRecommendation: (tab: ChromeTab, attribution: TabAttribution, idleSince: Date)? {
        let now = Date()
        return chromeTabs
            .filter { !$0.isActive }
            .compactMap { tab in
                guard let idleSince = chromeIdleSince[tab.idleKey],
                      now.timeIntervalSince(idleSince) >= 15 * 60,
                      let attribution = tabAttributions[tab.id],
                      attribution.totalBytes >= 500_000_000 else { return nil }
                return (tab: tab, attribution: attribution, idleSince: idleSince)
            }
            .max { $0.attribution.totalBytes < $1.attribution.totalBytes }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        pressureMonitor.onChange = { [weak self] kernelLevel in
            guard let self else { return }
            let availLevel = self.memory.map {
                PressureLevel(availableFraction: $0.totalBytes > 0
                    ? Double($0.availableBytes) / Double($0.totalBytes) : 1)
            } ?? .low
            self.pressureLevel = kernelLevel.combined(with: availLevel)
        }
        pressureMonitor.start()
        appsMonitor.start()

        // Prime topApps and memory once on launch so opening palette is instant
        refreshFast()
        refreshHistorySample()

        // Background timer for menu bar icon pressure (Mach VM statistics only: ~0% CPU, 0 allocations)
        vmTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, !self.isPaletteVisible else { return }
            self.refreshVMStats()
        }
        chromeAlertTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self,
                  !self.isPaletteVisible,
                  let memory = self.memory,
                  memory.usedFraction >= 0.85,
                  ChromeTabsBridge.isRunning else { return }
            self.refreshFast()
        }
        historyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshHistorySample() }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        pressureMonitor.stop()
        appsMonitor.stop()
        fastTimer?.invalidate()
        historyTimer?.invalidate()
        chromeTimer?.invalidate()
        chromeAlertTimer?.invalidate()
        vmTimer?.invalidate()
        fastTimer = nil
        historyTimer = nil
        chromeTimer = nil
        chromeAlertTimer = nil
        vmTimer = nil
    }

    func setPaletteVisible(_ visible: Bool) {
        guard isPaletteVisible != visible else { return }
        isPaletteVisible = visible

        if visible {
            // Instantly refresh on background queue so fresh data streams in without UI hitch
            refreshFast()
            startFastTimer()
        } else {
            stopFastTimer()
            stopWatchingChrome()
            cleanupMemoryOnDismiss()
        }
    }

    private func startFastTimer() {
        fastTimer?.invalidate()
        fastTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshFast()
        }
    }

    private func stopFastTimer() {
        fastTimer?.invalidate()
        fastTimer = nil
    }

    private func cleanupMemoryOnDismiss() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.appsMonitor.pruneCaches()
            malloc_zone_pressure_relief(malloc_default_zone(), 0)
        }
    }

    /// Ultra-lightweight Mach VM polling for menu bar icon when palette is closed.
    private func refreshVMStats() {
        workQueue.async { [weak self] in
            guard let self, let snapshot = MemoryStats.snapshot() else { return }
            DispatchQueue.main.async {
                self.memory = snapshot
                let availFraction = snapshot.totalBytes > 0
                    ? Double(snapshot.availableBytes) / Double(snapshot.totalBytes)
                    : 1.0
                let availLevel = PressureLevel(availableFraction: availFraction)
                let kernelLevel = self.pressureMonitor.level
                self.pressureLevel = kernelLevel.combined(with: availLevel)
            }
        }
    }

    private func refreshFast() {
        workQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = MemoryStats.snapshot()
            let processes = ProcessScanner.allProcesses()

            // 1. Inspect Chrome processes
            let chromeSamples = processes.filter { proc in
                if let path = proc.executablePath {
                    return path.contains("Google Chrome")
                }
                return false
            }

            let (helpers, distribution) = self.chromeInventory.inspect(samples: chromeSamples)
            let renderers = helpers.filter { $0.kind == .renderer }

            // 2. Fetch tabs only if Chrome watching is active (accordion expanded or Chrome state view)
            var currentTabs: [ChromeTab]? = nil
            let shouldMonitorChromeForAlert = self.memory?.usedFraction ?? 0 >= 0.85
            if (self.chromeTimer != nil || shouldMonitorChromeForAlert) && ChromeTabsBridge.isRunning {
                currentTabs = ChromeTabsBridge.fetchTabs()
            }

            // 3. Update tab memory tracker
            self.tabTracker.update(renderers: renderers, currentTabs: currentTabs)
            let attributions = self.tabTracker.attributions

            DispatchQueue.main.async {
                if let snapshot {
                    self.memory = snapshot
                    let availFraction = snapshot.totalBytes > 0
                        ? Double(snapshot.availableBytes) / Double(snapshot.totalBytes)
                        : 1.0
                    let availLevel = PressureLevel(availableFraction: availFraction)
                    let kernelLevel = self.pressureMonitor.level
                    self.pressureLevel = kernelLevel.combined(with: availLevel)
                }

                self.topApps = self.appsMonitor.aggregate(processes: processes)
                self.leftoverBackgroundGroups = self.appsMonitor.leftoverBackgroundGroups(processes: processes)
                // This state drives the tabs screen. It must be refreshed from
                // NSWorkspace on the main thread; otherwise `/tabs` can claim
                // Chrome is closed while its processes are visible elsewhere.
                self.chromeIsRunning = ChromeTabsBridge.isRunning
                self.chromeDistribution = distribution
                self.tabAttributions = attributions
                if let currentTabs {
                    self.chromeTabs = currentTabs
                    self.updateChromeIdleTracking(currentTabs)
                }
            }
        }
    }

    private func refreshHistorySample() {
        workQueue.async { [weak self] in
            guard let self, let snapshot = MemoryStats.snapshot() else { return }
            let percent = snapshot.usedFraction * 100
            DispatchQueue.main.async {
                if self.pressureSamples.isEmpty {
                    self.pressureSamples = Array(repeating: percent, count: 30)
                } else {
                    var samples = self.pressureSamples
                    samples.append(percent)
                    samples.removeFirst()
                    self.pressureSamples = samples
                }
            }
        }
    }

    // MARK: - Chrome

    private func updateChromeIdleTracking(_ tabs: [ChromeTab]) {
        let now = Date()
        let currentKeys = Set(tabs.map(\.idleKey))
        chromeIdleSince = chromeIdleSince.filter { currentKeys.contains($0.key) }

        for tab in tabs {
            if tab.isActive {
                chromeIdleSince[tab.idleKey] = nil
            } else if chromeIdleSince[tab.idleKey] == nil {
                chromeIdleSince[tab.idleKey] = now
            }
        }
    }

    func startWatchingChrome() {
        guard chromeTimer == nil else { return }
        refreshFast()
        chromeTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.refreshFast() }
    }

    func stopWatchingChrome() {
        chromeTimer?.invalidate()
        chromeTimer = nil
    }

    private func refreshChrome() {
        refreshFast()
    }

    // MARK: - Actions

    func quit(pid: pid_t, force: Bool = false) {
        appsMonitor.terminate(pid: pid, force: force)
        refreshFast()
    }

    func stopLeftoverProcesses(_ group: LeftoverBackgroundGroup) {
        appsMonitor.terminateLeftovers(group)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshFast()
        }
    }

    func activateChromeTab(_ tab: ChromeTab) {
        workQueue.async {
            ChromeTabsBridge.activateTab(id: tab.id)
        }
    }

    func quitChrome() {
        workQueue.async { ChromeTabsBridge.quit() }
    }
}
