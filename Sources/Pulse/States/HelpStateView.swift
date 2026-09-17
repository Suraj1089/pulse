import SwiftUI

/// Shows interactive help for slash commands, syntax, and keyboard shortcuts.
/// Clicking any command automatically populates it in the search field.
struct HelpStateView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel
    @State private var hoveredCommand: String?

    var body: some View {
        let theme = Theme(scheme: scheme)

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Available slash commands").padding(.top, 8).padding(.bottom, 6)

            VStack(spacing: 2) {
                ForEach(SlashCommand.all) { cmd in
                    commandRow(cmd, theme: theme)
                }
            }

            SectionHeader(title: "Keyboard shortcuts").padding(.top, 14).padding(.bottom, 6)

            VStack(spacing: 4) {
                shortcutRow(keys: "⌘ ⌥ P", desc: "Toggle Pulse palette from anywhere", theme: theme)
                shortcutRow(keys: "↵", desc: "Execute command or quit selected app", theme: theme)
                shortcutRow(keys: "↑ ↓", desc: "Navigate suggestions and app lists", theme: theme)
                shortcutRow(keys: "esc", desc: "Close command palette", theme: theme)
            }
            .padding(.horizontal, Metrics.rowSidePadding)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.bottom, 12)
    }

    // MARK: - Row Views

    @ViewBuilder
    private func commandRow(_ cmd: SlashCommand, theme: Theme) -> some View {
        let isHovered = hoveredCommand == cmd.id

        Button {
            model.query = cmd.template
        } label: {
            HStack(spacing: 11) {
                Image(systemName: cmd.iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .frame(width: 22, height: 22)
                    .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(cmd.name)
                        .font(Fonts.mono)
                        .foregroundStyle(theme.textPrimary)

                    Text(cmd.description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textDim)
                }

                Spacer()

                Text("e.g. \(cmd.example)")
                    .font(Fonts.monoTiny)
                    .foregroundStyle(theme.hint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.trackBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .padding(.horizontal, Metrics.rowSidePadding)
            .frame(height: 42)
            .background(isHovered ? theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredCommand = hovering ? cmd.id : (hoveredCommand == cmd.id ? nil : hoveredCommand)
        }
    }

    @ViewBuilder
    private func shortcutRow(keys: String, desc: String, theme: Theme) -> some View {
        HStack {
            Text(desc)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)

            Spacer()

            Text(keys)
                .font(Fonts.monoSmall)
                .foregroundStyle(theme.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        }
        .padding(.vertical, 3)
    }
}
