import AppKit

// main.swift always executes on the main thread, so assumeIsolated is safe.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
}
NSApplication.shared.run()
