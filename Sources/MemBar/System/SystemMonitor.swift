import Foundation

/// Owns every live data source (kernel memory stats, the pressure dispatch
/// source, process enumeration, Chrome) and publishes what the views need.
///
/// Two different polling cadences, matching how expensive/volatile each
/// source is: memory + top apps refresh every 3s (process enumeration over
/// a few hundred processes is a few ms of work, cheap enough for that); the
/// 30-sample "last 30 min" pressure history appends one real sample every
/// 60s. Chrome is **not** polled continuously — `startWatchingChrome()` is
/// only called while the palette is actually showing the Chrome-tabs state,
/// both because AppleScript round-trips are comparatively slow and because
/// the first call blocks on an Automation permission dialog.
final class SystemMonitor: ObservableObject {
    @Published private(set) var memory: MemorySnapshot?
    @Published private(set) var pressureLevel: PressureLevel = .low
    @Published private(set) var topApps: [RunningAppUsage] = []
    @Published private(set) var pressureSamples: [Double] = []
    @Published private(set) var chromeTabs: [ChromeTab] = []
    @Published private(set) var chromeIsRunning = false

    private let pressureMonitor = PressureMonitor()
    private let appsMonitor = RunningAppsMonitor()
    private let workQueue = DispatchQueue(label: "app.membar.system-monitor", qos: .utility)

    private var fastTimer: Timer?
    private var historyTimer: Timer?
    private var chromeTimer: Timer?

    func start() {
        pressureMonitor.onChange = { [weak self] level in self?.pressureLevel = level }
        pressureMonitor.start()
        appsMonitor.start()

        refreshFast()
        refreshHistorySample()

        fastTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshFast() }
        historyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshHistorySample() }
    }

    func stop() {
        pressureMonitor.stop()
        appsMonitor.stop()
        fastTimer?.invalidate()
        historyTimer?.invalidate()
        chromeTimer?.invalidate()
        fastTimer = nil
        historyTimer = nil
        chromeTimer = nil
    }

    private func refreshFast() {
        workQueue.async { [weak self] in
            guard let self else { return }
            // Pure libproc syscalls — safe off the main thread, and the
            // expensive part (enumerating every process on the system).
            let snapshot = MemoryStats.snapshot()
            let processes = ProcessScanner.allProcesses()
            DispatchQueue.main.async {
                // NSWorkspace/NSRunningApplication access must happen on main.
                if let snapshot { self.memory = snapshot }
                self.topApps = self.appsMonitor.aggregate(processes: processes)
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

    func startWatchingChrome() {
        guard chromeTimer == nil else { return }
        refreshChrome()
        chromeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshChrome() }
    }

    func stopWatchingChrome() {
        chromeTimer?.invalidate()
        chromeTimer = nil
    }

    private func refreshChrome() {
        // NSWorkspace read — must be on main; refreshChrome() is only ever
        // invoked from a main-thread Timer callback or a direct call.
        let running = ChromeTabsBridge.isRunning
        chromeIsRunning = running
        guard running else {
            chromeTabs = []
            return
        }
        workQueue.async { [weak self] in
            // The AppleScript round-trip itself is fine off-main — it's the
            // slow part, and the first call blocks on a permission dialog.
            let tabs = ChromeTabsBridge.fetchTabs() ?? []
            DispatchQueue.main.async { self?.chromeTabs = tabs }
        }
    }

    // MARK: - Actions

    func quit(pid: pid_t, force: Bool = false) {
        appsMonitor.terminate(pid: pid, force: force)
        refreshFast()
    }

    func closeChromeTab(_ tab: ChromeTab) {
        workQueue.async { [weak self] in
            ChromeTabsBridge.closeTab(windowIndex: tab.windowIndex, tabIndex: tab.tabIndex)
            DispatchQueue.main.async { self?.refreshChrome() }
        }
    }

    func closeBackgroundChromeTabs() {
        let tabs = chromeTabs
        workQueue.async { [weak self] in
            ChromeTabsBridge.closeBackgroundTabs(tabs)
            DispatchQueue.main.async { self?.refreshChrome() }
        }
    }

    func quitChrome() {
        workQueue.async { ChromeTabsBridge.quit() }
    }
}
