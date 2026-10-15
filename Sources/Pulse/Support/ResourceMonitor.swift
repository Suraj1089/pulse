import Darwin
import Foundation

struct ResourceSnapshot {
    let appMemory: String
    let appCPU: String
    let childMemory: String?
}

/// Reads Pulse's own physical footprint and CPU time with `proc_pid_rusage`,
/// plus the footprint of its direct children (terminal shells). Child memory
/// is reported separately so the editor's number stays honest.
///
/// It samples every 2 s only while Pulse is the active app; it is stopped
/// otherwise, so an idle, unfocused Pulse makes no periodic wakeups.
final class ResourceMonitor {
    var onUpdate: ((ResourceSnapshot) -> Void)?

    private var timer: Timer?
    private var lastCPU: UInt64 = 0
    private var lastWall: UInt64 = 0
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func sample() {
        guard let own = ResourceMonitor.usage(of: getpid()) else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let cpuNanos = own.cpuTicks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
        var cpuPercent = 0.0
        if lastWall > 0, now > lastWall {
            cpuPercent = Double(cpuNanos &- lastCPU) / Double(now - lastWall) * 100
        }
        lastCPU = cpuNanos
        lastWall = now

        let children = ResourceMonitor.childPIDs().compactMap { ResourceMonitor.usage(of: $0)?.footprint }
        let snapshot = ResourceSnapshot(
            appMemory: ResourceMonitor.format(bytes: own.footprint),
            appCPU: String(format: "%.0f%%", max(0, cpuPercent)),
            childMemory: children.isEmpty ? nil : ResourceMonitor.format(bytes: children.reduce(0, +))
        )
        onUpdate?(snapshot)
    }

    static func usage(of pid: pid_t) -> (footprint: UInt64, cpuTicks: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return (info.ri_phys_footprint, info.ri_user_time + info.ri_system_time)
    }

    static func childPIDs() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listchildpids(getpid(), buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return pids.filter { $0 > 0 }
    }

    static func format(bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        return megabytes >= 1024
            ? String(format: "%.1f GB", megabytes / 1024)
            : String(format: "%.0f MB", megabytes)
    }
}
