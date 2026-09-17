import Dispatch
import Foundation

/// Wraps the kernel's authoritative memory-pressure signal
/// (`DispatchSource.makeMemoryPressureSource`, the same notification Activity
/// Monitor's pressure gauge and `memory_pressure -Q` read) instead of
/// re-deriving LOW/MEDIUM/HIGH from a used-memory percentage.
final class PressureMonitor {
    private(set) var level: PressureLevel = .low
    private var source: DispatchSourceMemoryPressure?
    var onChange: (PressureLevel) -> Void = { _ in }

    func start() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            let level: PressureLevel = event.contains(.critical) ? .high : event.contains(.warning) ? .medium : .low
            self.level = level
            self.onChange(level)
        }
        source.activate()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
