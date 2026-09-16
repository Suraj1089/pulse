import SwiftUI

/// Menu-bar-only app: all UI is owned by `AppDelegate` (status item + panel),
/// so the Scene here is an inert `Settings` scene — it satisfies `App` without
/// opening a window at launch.
@main
struct MemPaletteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {}
    }
}
