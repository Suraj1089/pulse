import Darwin
import Foundation

/// One running process's identity and resident memory, read via `libproc`.
struct ProcessSample {
    let pid: pid_t
    let executablePath: String?
    /// `ri_phys_footprint` — the same "real memory" figure Activity Monitor's
    /// Memory column shows (distinct from, and more accurate than, RSS).
    let physFootprintBytes: UInt64
}

/// Enumerates every process visible to the current user via `libproc`
/// (`proc_listpids` / `proc_pidpath` / `proc_pid_rusage`) — no elevated
/// privileges required to read your own processes' memory footprint.
enum ProcessScanner {
    static func allProcesses() -> [ProcessSample] {
        allPIDs().compactMap { pid in
            guard let footprint = physFootprint(of: pid) else { return nil }
            return ProcessSample(pid: pid, executablePath: path(of: pid), physFootprintBytes: footprint)
        }
    }

    private static func allPIDs() -> [pid_t] {
        let neededBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard neededBytes > 0 else { return [] }
        // Double the reported size: the process list can grow between the
        // sizing call and the fetch call.
        let capacity = (Int(neededBytes) / MemoryLayout<pid_t>.stride) * 2
        var buffer = [pid_t](repeating: 0, count: max(capacity, 1))
        let writtenBytes = buffer.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, Int32(raw.count))
        }
        guard writtenBytes > 0 else { return [] }
        let count = Int(writtenBytes) / MemoryLayout<pid_t>.stride
        return Array(buffer.prefix(count)).filter { $0 > 0 }
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func physFootprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { infoPtr -> Int32 in
            infoPtr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPtr)
            }
        }
        guard result == 0 else { return nil }
        return info.ri_phys_footprint
    }
}
