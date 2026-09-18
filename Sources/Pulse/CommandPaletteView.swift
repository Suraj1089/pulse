import SwiftUI

/// CommandPaletteWindow root: SearchField header, the query-routed content
/// area, and the footer key hints. 560pt wide, 400...480pt tall, then scrolls.
struct CommandPaletteView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel
    @FocusState private var searchFocused: Bool
    var onEscape: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            // Brand header: Logo, Pulse, Find. Free. Focus., RAM progress
            PulseBrandHeader(
                usedGB: model.usedGB,
                totalGB: model.totalGB,
                level: model.level
            )

            // Minimalist pill search bar
            SearchFieldView(
                query: $model.query,
                showKeyHints: model.showKeyHints,
                isFocused: $searchFocused,
                onSubmit: handleSearchSubmit,
                onTab: completeCommandSuggestion
            )

            ScrollView(showsIndicators: false) {
                Group {
                    switch model.state {
                    case .overview: OverviewStateView(model: model)
                    case .diagnosis: DiagnosisStateView(model: model)
                    case .memory: MemoryStateView(model: model)
                    case .close: CloseStateView(model: model)
                    case .chromeTabs: ChromeTabsStateView(model: model)
                    case .help: HelpStateView(model: model)
                    case .version: UpdateStateView(model: model)
                    case .update: UpdateStateView(model: model)
                    case .quitCommand(let appQuery, let isForce): QuitCommandStateView(model: model, appQuery: appQuery, isForce: isForce)
                    case .commandSuggestions(let filter): CommandSuggestionsView(model: model, filter: filter)
                    case .noMatch: NoMatchStateView()
                    }
                }
            }
            .frame(maxHeight: .infinity)

            // Modern minimalist footer
            ModernFooterView(
                onSettings: { model.query = "/help" },
                onUpdate: { model.query = "/update" }
            )
        }
        .frame(width: Metrics.windowWidth, height: 490)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: Metrics.windowRadius, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: Metrics.windowRadius, style: .continuous)
                    .fill(scheme == .dark
                        ? Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.85)
                        : Color.white.opacity(0.72))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.windowRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.windowRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: scheme == .dark ? Color.white.opacity(0.20) : Color.white.opacity(0.65), location: 0),
                            .init(color: scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), location: 0.25),
                            .init(color: scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.10), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .onAppear {
            model.start()
            searchFocused = true
        }
        .onExitCommand(perform: onEscape)
    }

    private var footerItems: [String] {
        switch model.state {
        case .chromeTabs:
            return ["click a tab to open it in Chrome", "esc close"]
        case .quitCommand(_, let isForce):
            return isForce ? ["↑↓ select", "↵ force quit (SIGKILL)", "esc close"] : ["↑↓ select", "↵ quit app", "esc close"]
        case .commandSuggestions:
            return ["↑↓ select", "↵ complete", "esc close"]
        case .help:
            return ["click command to run", "esc close"]
        default:
            return ["↑↓ navigate", "↵ select", "esc close"]
        }
    }

    private func handleSearchSubmit() {
        switch model.state {
        case .commandSuggestions(let filter):
            if let topCmd = model.matchingCommands(for: filter).first {
                model.query = topCmd.template
            }
        case .quitCommand(let appQuery, let isForce):
            if let topApp = model.matchingApps(for: appQuery).first {
                model.quit(pid: topApp.id, force: isForce)
                model.query = ""
            }
        case .help:
            break
        default:
            break
        }
    }

    /// Accept the top slash-command suggestion without running it. This keeps
    /// Tab predictable: `/hel` becomes `/help`, while Return remains the
    /// command-selection key.
    private func completeCommandSuggestion() -> Bool {
        guard case .commandSuggestions(let filter) = model.state,
              let command = model.matchingCommands(for: filter).first else {
            return false
        }
        model.query = command.template
        return true
    }
}
