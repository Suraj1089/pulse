import SwiftUI

struct QuitButton: View {
    @Environment(\.colorScheme) private var scheme
    var label = "Quit"
    var filled = false
    var action: () -> Void = {}

    var body: some View {
        let theme = Theme(scheme: scheme)
        Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.quitText)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(filled ? Color(oklch: 0.55, 0.15, 25, opacity: 0.16) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(theme.quitBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
