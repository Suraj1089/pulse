import AppKit

// Pulse is a plain AppKit app: no SwiftUI, no storyboards, no XIBs.
// Everything the window shows is built in code so nothing is loaded that
// the editor does not use.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
