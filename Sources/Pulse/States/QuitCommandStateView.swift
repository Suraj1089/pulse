import SwiftUI

/// Handles `/quit <appname>` with real-time auto-suggestions as the user types.
/// Supports both keyboard navigation (Return to quit top match) and click-to-quit
/// with the fluid Apple-style dismissal animation.
struct QuitCommandStateView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel
    let appQuery: String
    var isForce: Bool = false

    @State private var selectedIndex = 0
    @State private var quittingPIDs: Set<pid_t> = []

    private var matchingApps: [AppUsage] {
        model.matchingApps(for: appQuery).filter { !quittingPIDs.contains($0.id) }
    }

    var body: some View {
        let theme = Theme(scheme: scheme)

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(
                    title: appQuery.isEmpty
                        ? (isForce ? "Force kill applications (\(matchingApps.count))" : "Running applications (\(matchingApps.count))")
                        : (isForce ? "Force kill \"\(appQuery)\" (\(matchingApps.count))" : "Suggestions for \"\(appQuery)\" (\(matchingApps.count))")
                )
                Spacer()
                if !matchingApps.isEmpty {
                    Text(isForce ? "↵ force kills top match" : "↵ quits top match")
                        .font(Fonts.monoTiny)
                        .foregroundStyle(isForce ? Color(red: 1.0, green: 0.4, blue: 0.4) : theme.hint)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 6)

            if matchingApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.app.dashed")
                        .font(.system(size: 28))
                        .foregroundStyle(theme.textDim)

                    Text(appQuery.isEmpty ? "No running applications found" : "No running apps matching \"\(appQuery)\"")
                        .font(Fonts.body)
                        .foregroundStyle(theme.textDim)

                    Text("Try typing an app name like \"Chrome\", \"Slack\", or \"Code\"")
                        .font(Fonts.monoSmall)
                        .foregroundStyle(theme.hint)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(matchingApps.enumerated()), id: \.element.id) { index, app in
                        AppListItem(
                            app: app,
                            isSelected: selectedIndex == index,
                            quitMode: .always,
                            quitLabel: isForce ? "Force Quit" : "Quit",
                            isDestructive: isForce,
                            onHover: { hovering in
                                if hovering && selectedIndex != index {
                                    selectedIndex = index
                                }
                            },
                            onQuit: { animatedQuit(pid: app.id) }
                        )
                        .transition(.quitSweep)
                    }
                }
                .clipped()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.bottom, 10)
        .onAppear { selectedIndex = 0 }
        .onChange(of: appQuery) { _, _ in
            selectedIndex = 0
        }
        .onChange(of: model.apps.map { $0.id }) { _, liveIDs in
            quittingPIDs = quittingPIDs.filter { liveIDs.contains($0) }
        }
    }

    // MARK: - Animated Quit

    private func animatedQuit(pid: pid_t) {
        _ = withAnimation(.quitSpring) {
            quittingPIDs.insert(pid)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            model.quit(pid: pid, force: isForce)
        }
    }
}
