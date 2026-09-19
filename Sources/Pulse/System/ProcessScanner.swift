import Darwin
import Foundation

/// One running process's identity plus resident and footprint measurements,
/// read via `libproc`.
struct ProcessSample {
    let pid: pid_t
    let executablePath: String?
    /// `ri_resident_size` — physical pages currently resident for this process.
    let residentBytes: UInt64
    /// `ri_phys_footprint` — useful for ranking a process, but process
    /// footprints can share pages and must not be added up as physical RAM.
    let physFootprintBytes: UInt64
}

/// Enumerates every process visible to the current user via `libproc`
/// (`proc_listpids` / `proc_pidpath` / `proc_pid_rusage`) — no elevated
/// privileges required to read your own processes' memory footprint.
enum ProcessScanner {
    private static var pathCache: [pid_t: String] = [:]

    static func allProcesses() -> [ProcessSample] {
        let pids = allPIDs()
        let pidSet = Set(pids)

        // Evict dead PIDs when cache grows excessively
        if pathCache.count > pids.count + 200 {
            pathCache = pathCache.filter { pidSet.contains($0.key) }
        }

        return pids.compactMap { pid in
            guard let memory = memoryInfo(of: pid) else { return nil }
            let execPath: String?
            if let cached = pathCache[pid] {
                execPath = cached
            } else {
                let p = path(of: pid)
                if let p { pathCache[pid] = p }
                execPath = p
            }
            return ProcessSample(
                pid: pid,
                executablePath: execPath,
                residentBytes: memory.residentBytes,
                physFootprintBytes: memory.physFootprintBytes
            )
        }
    }

    static func identity(of pid: pid_t) -> (parentPID: pid_t, startDate: Date)? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let bytesRead = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(expectedSize))
        }
        guard bytesRead == expectedSize, info.pbi_start_tvsec > 0 else { return nil }
        return (
            parentPID: pid_t(info.pbi_ppid),
            startDate: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
        )
    }

    private static func allPIDs() -> [pid_t] {
        let neededBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard neededBytes > 0 else { return [] }
        let capacity = (Int(neededBytes) / MemoryLayout<pid_t>.stride) * 2
        var buffer = [pid_t](repeating: 0, count: max(capacity, 1))
        let writtenBytes = buffer.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, Int32(raw.count))
        }
        guard writtenBytes > 0 else { return [] }
        let count = Int(writtenBytes) / MemoryLayout<pid_t>.stride
        var result: [pid_t] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let pid = buffer[i]
            if pid > 0 { result.append(pid) }
        }
        return result
    }

    static func path(of pid: pid_t) -> String? {
        let maxLen = 4 * Int(MAXPATHLEN)
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: maxLen) { buffer in
            guard let base = buffer.baseAddress else { return nil }
            let length = proc_pidpath(pid, base, UInt32(maxLen))
            guard length > 0 else { return nil }
            return String(cString: base)
        }
    }

    private static func memoryInfo(of pid: pid_t) -> (residentBytes: UInt64, physFootprintBytes: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { infoPtr -> Int32 in
            infoPtr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPtr)
            }
        }
        guard result == 0 else { return nil }
        return (info.ri_resident_size, info.ri_phys_footprint)
    }
}
