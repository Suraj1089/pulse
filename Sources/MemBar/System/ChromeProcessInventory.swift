import Darwin
import Foundation

enum ProcessArguments {
    /// argv via sysctl(KERN_PROCARGS2). Works against Chrome's hardened-runtime
    /// renderers without root privileges.
    static func arguments(of pid: pid_t) -> [String]? {
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var argmaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMIB, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(argmax))
        var size = Int(argmax)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }

        // Layout: argc(Int32) | exec_path\0 | \0 padding | argv[0..argc-1] | env
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }

        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }   // skip exec_path
        while i < size && buffer[i] == 0 { i += 1 }   // skip NUL padding

        var args: [String] = []
        var current: [CChar] = []
        while i < size && args.count < Int(argc) {
            if buffer[i] == 0 {
                current.append(0)
                args.append(String(cString: current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(buffer[i])
            }
            i += 1
        }
        return args
    }
}

/// A classified Chrome helper process.
struct ChromeHelper: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case renderer = "Renderer"
        case extensionRenderer = "Extension"
        case gpu = "GPU"
        case network = "Network"
        case utility = "Utility"
        case other = "Other"
    }

    var id: pid_t { pid }
    let pid: pid_t
    let kind: Kind
    /// --renderer-client-id — dense monotonic counter from Chromium.
    let clientID: Int?
    /// --launch-time-ticks — Chromium base::TimeTicks (microseconds).
    let launchTicks: UInt64?
    var footprintBytes: UInt64

    var footprintMB: Double { Double(footprintBytes) / 1_000_000 }
    var footprintGB: Double { Double(footprintBytes) / 1_073_741_824 }
}

/// Summary of Chrome's helper process distribution.
struct ChromeDistribution: Equatable {
    let totalFootprintBytes: UInt64
    let totalProcessCount: Int
    let rendererCount: Int
    let extensionCount: Int
    let extensionFootprintBytes: UInt64
    let largestRendererBytes: UInt64
    let highCount: Int      // > 180 MB
    let mediumCount: Int    // 60–180 MB
    let lowCount: Int       // < 60 MB
    let overheadBytes: UInt64
    let overheadProcessCount: Int

    var totalGB: Double { Double(totalFootprintBytes) / 1_073_741_824 }
    var overheadGB: Double { Double(overheadBytes) / 1_073_741_824 }
    var extensionMB: Double { Double(extensionFootprintBytes) / 1_000_000 }
    var largestRendererMB: Double { Double(largestRendererBytes) / 1_000_000 }
}

/// Tracks and classifies Chrome processes, caching argv to avoid re-reading
/// sysctl on every tick for known PIDs.
final class ChromeProcessInventory {
    struct CachedMeta {
        let kind: ChromeHelper.Kind
        let clientID: Int?
        let launchTicks: UInt64?
    }

    private var cache: [pid_t: CachedMeta] = [:]

    /// Classify a list of process samples belonging to Chrome.
    func inspect(samples: [ProcessSample]) -> ([ChromeHelper], ChromeDistribution) {
        let currentPIDs = Set(samples.map { $0.pid })
        // Evict dead PIDs from cache
        cache = cache.filter { currentPIDs.contains($0.key) }

        var helpers: [ChromeHelper] = []
        var largestRenderer: UInt64 = 0
        var high = 0
        var med = 0
        var low = 0
        var extCount = 0
        var extBytes: UInt64 = 0
        var rendererCount = 0
        var overheadBytes: UInt64 = 0
        var overheadCount = 0

        for sample in samples {
            let meta: CachedMeta
            if let cached = cache[sample.pid] {
                meta = cached
            } else {
                let parsed = parseArguments(for: sample.pid)
                cache[sample.pid] = parsed
                meta = parsed
            }

            let helper = ChromeHelper(
                pid: sample.pid,
                kind: meta.kind,
                clientID: meta.clientID,
                launchTicks: meta.launchTicks,
                footprintBytes: sample.physFootprintBytes
            )
            helpers.append(helper)

            switch meta.kind {
            case .renderer:
                rendererCount += 1
                if sample.physFootprintBytes > largestRenderer {
                    largestRenderer = sample.physFootprintBytes
                }
                let mb = sample.physFootprintBytes / 1_000_000
                if mb > 180 { high += 1 }
                else if mb >= 60 { med += 1 }
                else { low += 1 }
            case .extensionRenderer:
                extCount += 1
                extBytes += sample.physFootprintBytes
            case .gpu, .network, .utility, .other:
                overheadCount += 1
                overheadBytes += sample.physFootprintBytes
            }
        }

        let totalBytes = samples.reduce(UInt64(0)) { $0 + $1.physFootprintBytes }
        let dist = ChromeDistribution(
            totalFootprintBytes: totalBytes,
            totalProcessCount: samples.count,
            rendererCount: rendererCount,
            extensionCount: extCount,
            extensionFootprintBytes: extBytes,
            largestRendererBytes: largestRenderer,
            highCount: high,
            mediumCount: med,
            lowCount: low,
            overheadBytes: overheadBytes,
            overheadProcessCount: overheadCount
        )

        return (helpers, dist)
    }

    private func parseArguments(for pid: pid_t) -> CachedMeta {
        guard let args = ProcessArguments.arguments(of: pid) else {
            return CachedMeta(kind: .other, clientID: nil, launchTicks: nil)
        }

        var type: String?
        var isExtension = false
        var clientID: Int?
        var launchTicks: UInt64?

        for arg in args {
            if arg.hasPrefix("--type=") {
                type = String(arg.dropFirst(7))
            } else if arg == "--extension-process" {
                isExtension = true
            } else if arg.hasPrefix("--renderer-client-id=") {
                clientID = Int(arg.dropFirst(21))
            } else if arg.hasPrefix("--launch-time-ticks=") {
                launchTicks = UInt64(arg.dropFirst(20))
            }
        }

        let kind: ChromeHelper.Kind
        if type == "renderer" {
            kind = isExtension ? .extensionRenderer : .renderer
        } else if type == "gpu-process" {
            kind = .gpu
        } else if type == "utility" {
            kind = .utility
        } else if type == "network" {
            kind = .network
        } else if type == nil {
            // Main browser process
            kind = .other
        } else {
            kind = .other
        }

        return CachedMeta(kind: kind, clientID: clientID, launchTicks: launchTicks)
    }
}
