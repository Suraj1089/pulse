import SwiftUI

/// Shows the current Pulse version and lets users check / install updates.
/// Used by both `/version` and `/update` palette commands.
struct UpdateStateView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        let theme = Theme(scheme: scheme)

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Version & Updates")
                .padding(.top, 8)
                .padding(.bottom, 10)

            // Current version card
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .frame(width: 36, height: 36)
                    .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Pulse")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Version \(checker.currentVersion)")
                        .font(Fonts.mono)
                        .foregroundStyle(theme.textDim)
                }

                Spacer()

                statusBadge(theme: theme)
            }
            .padding(.horizontal, Metrics.rowSidePadding)
            .frame(height: 56)
            .background(theme.trackBackground, in: RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 0.8)
            )

            // Action area
            actionArea(theme: theme)
                .padding(.top, 14)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.bottom, 12)
        .onAppear {
            if checker.checkState == .idle {
                checker.checkForUpdates()
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func statusBadge(theme: Theme) -> some View {
        switch checker.checkState {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Checking…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textDim)
            }
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color(oklch: 0.64, 0.13, 150))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(oklch: 0.64, 0.13, 150).opacity(0.12), in: Capsule())
        case .updateAvailable(let latest):
            Text("v\(latest) available")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.accent.opacity(0.12), in: Capsule())
        case .error:
            Label("Check failed", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(Color(oklch: 0.62, 0.16, 25))
        }
    }

    @ViewBuilder
    private func actionArea(theme: Theme) -> some View {
        switch checker.updateState {
        case .idle:
            idleActions(theme: theme)
        case .downloading(let progress):
            downloadingView(progress: progress, theme: theme)
        case .installing:
            installingView(theme: theme)
        case .done:
            doneView(theme: theme)
        case .error(let msg):
            errorView(msg, theme: theme)
        }
    }

    @ViewBuilder
    private func idleActions(theme: Theme) -> some View {
        switch checker.checkState {
        case .updateAvailable(let latest):
            // Primary: install update
            Button {
                checker.performUpdate()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14))
                    Text("Install v\(latest) — Pulse will restart")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

        case .upToDate, .idle, .checking:
            // Secondary: re-check or silent
            Button {
                checker.checkForUpdates()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                    Text("Check for updates")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(theme.trackBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)
            .disabled(checker.checkState == .checking)

        case .error(let msg):
            VStack(alignment: .leading, spacing: 4) {
                Text("Could not check for updates: \(msg)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(oklch: 0.62, 0.16, 25))
                Button("Try again") { checker.checkForUpdates() }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func downloadingView(progress: Double, theme: Theme) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("Downloading…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(Fonts.monoTiny)
                    .foregroundStyle(theme.textDim)
            }
            ProgressView(value: progress)
                .tint(theme.accent)
        }
    }

    @ViewBuilder
    private func installingView(theme: Theme) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Installing… Pulse will restart shortly")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder
    private func doneView(theme: Theme) -> some View {
        Label("Done! Relaunching…", systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(oklch: 0.64, 0.13, 150))
    }

    @ViewBuilder
    private func errorView(_ msg: String, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Update failed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(oklch: 0.62, 0.16, 25))
            Text(msg)
                .font(.system(size: 11))
                .foregroundStyle(theme.textDim)
                .lineLimit(2)
            Button("Try again") { checker.performUpdate() }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
        }
    }
}
