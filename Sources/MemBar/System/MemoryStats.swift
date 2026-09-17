import Darwin
import Foundation

/// A snapshot of system-wide physical memory, broken down the way Activity
/// Monitor's memory graph is (App Memory / Wired / Compressed / Cached / Free),
/// read straight from the kernel via `host_statistics64`.
struct MemorySnapshot {
    let totalBytes: UInt64
    let freeBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    /// `internal_page_count - purgeable_count` — resident app-owned memory.
    let appBytes: UInt64
    /// `external_page_count + purgeable_count` — reclaimable file-backed/purgeable pages.
    let cachedBytes: UInt64

    /// Matches Activity Monitor "Memory Used" = Wired + App + Compressed.
    var usedBytes: UInt64 { wiredBytes + appBytes + compressedBytes }

    /// True available = free pages + cached (file-backed pages macOS evicts on demand).
    /// Much more useful than raw free_count which is usually tiny on a busy system.
    var availableBytes: UInt64 { freeBytes + cachedBytes }

    var usedFraction: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) }

    // Activity Monitor displays RAM in binary gibibytes labelled "GB".
    // Divide by 2^30 (1 GiB), not by 10^9.
    private static let gib: Double = 1_073_741_824
    var freeGB:      Double { Double(freeBytes)      / Self.gib }
    var usedGB:      Double { Double(usedBytes)      / Self.gib }
    var totalGB:     Double { Double(totalBytes)     / Self.gib }
    var cachedGB:    Double { Double(cachedBytes)    / Self.gib }
    var availableGB: Double { Double(availableBytes) / Self.gib }
}

enum MemoryStats {
    /// Reads live `vm_statistics64` from the kernel. Returns `nil` on the
    /// (practically never hit) failure path so callers can hold their last
    /// good snapshot rather than showing zeroed-out numbers.
    static func snapshot() -> MemorySnapshot? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { statsPtr -> kern_return_t in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = UInt64(pageSize)
        let free = UInt64(stats.free_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let purgeable = UInt64(stats.purgeable_count) * page
        let external = UInt64(stats.external_page_count) * page
        let internalMem = UInt64(stats.internal_page_count) * page
        let app = internalMem > purgeable ? internalMem - purgeable : 0
        let cached = external + purgeable

        return MemorySnapshot(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            freeBytes: free,
            wiredBytes: wired,
            compressedBytes: compressed,
            appBytes: app,
            cachedBytes: cached
        )
    }
}
