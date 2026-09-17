import SwiftUI

/// Minimalist footer with Settings, optional update pill, and Quit All actions.
struct ModernFooterView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var checker = UpdateChecker.shared
    var onSettings: () -> Void = {}
    var onUpdate: () -> Void = {}

    var body: some View {
        let theme = Theme(scheme: scheme)

        HStack {
            Button(action: onSettings) {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11.5))
                    Text("Settings")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(theme.textSecondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Update pill — only shown when a newer version is available
            if case .updateAvailable(let latest) = checker.checkState {
                Button(action: onUpdate) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Update to v\(latest)")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.accent.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.accent.opacity(0.25), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))

                Spacer()
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "power")
                        .font(.system(size: 10.5, weight: .medium))
                    Text("Quit Pulse")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(theme.textSecondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .frame(height: Metrics.footerHeight)
        .animation(.easeInOut(duration: 0.25), value: checker.checkState == .upToDate)
        .onAppear {
            // Quietly check for updates in background when palette opens
            if checker.checkState == .idle {
                checker.checkForUpdates()
            }
        }
    }
}
