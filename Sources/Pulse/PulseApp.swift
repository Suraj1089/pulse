import SwiftUI

/// Kept for SwiftUI view previews. Entry point has moved to main.swift
/// (pure AppKit) to avoid SwiftUI scene lifecycle issues with LSUIElement apps.
struct PulseApp: App {
    var body: some Scene {
        Settings {}
    }
}
