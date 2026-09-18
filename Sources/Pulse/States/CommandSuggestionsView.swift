import SwiftUI

/// Displayed when the user types a leading `/` (e.g. `/`, `/q`, `/h`).
/// Shows real-time matching slash commands that can be selected or tab-completed.
struct CommandSuggestionsView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel
    let filter: String
    @State private var selectedIndex = 0

    private var commands: [SlashCommand] {
        model.matchingCommands(for: filter)
    }

    var body: some View {
        let theme = Theme(scheme: scheme)

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Commands").padding(.top, 8).padding(.bottom, 6)

            if commands.isEmpty {
                VStack(spacing: 6) {
                    Text("No commands matching \"/\(filter)\"")
                        .font(Fonts.body)
                        .foregroundStyle(theme.textDim)
                    Text("Type /help to see all available commands")
                        .font(Fonts.monoSmall)
                        .foregroundStyle(theme.hint)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, cmd in
                        let isSelected = selectedIndex == index

                        Button {
                            model.query = cmd.template
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: cmd.iconName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(isSelected ? theme.accent : theme.textMuted)
                                    .frame(width: 22, height: 22)
                                    .background(
                                        isSelected ? theme.accent.opacity(0.18) : theme.trackBackground,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(cmd.name)
                                        .font(Fonts.mono)
                                        .foregroundStyle(theme.textPrimary)

                                    Text(cmd.description)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(theme.textDim)
                                }

                                Spacer()

                                Text("⇥ complete")
                                    .font(Fonts.monoTiny)
                                    .foregroundStyle(isSelected ? theme.accent : Color.clear)
                            }
                            .padding(.horizontal, Metrics.rowSidePadding)
                            .frame(height: 42)
                            .background(
                                isSelected ? theme.rowSelected : .clear,
                                in: RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering && selectedIndex != index {
                                selectedIndex = index
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.bottom, 10)
        .onAppear { selectedIndex = 0 }
    }
}
