import SwiftUI

/// Minimalist pill search bar matching the premium UI:
/// Translucent pill container, magnifying glass, placeholder, and ⌘K badge.
struct SearchFieldView: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var query: String
    var showKeyHints: Bool
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}
    var onTab: () -> Bool = { false }

    var body: some View {
        let theme = Theme(scheme: scheme)

        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.searchIcon)

            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Search apps, tabs or processes…")
                        .font(Fonts.query)
                        .foregroundStyle(theme.placeholder)
                }
                SearchFieldRepresentable(
                    text: $query,
                    isFocused: isFocused.wrappedValue,
                    onSubmit: onSubmit,
                    onTab: onTab
                )
                .frame(height: 22)
            }

            if query.isEmpty && showKeyHints {
                HStack(spacing: 2) {
                    Text("⌘")
                    Text("K")
                }
                .font(Fonts.monoTiny)
                .foregroundStyle(theme.hint)
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background(theme.pillBackground, in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(theme.pillBorder, lineWidth: 0.8))
            } else if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 35)
        .background(theme.pillBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.pillBorder, lineWidth: 0.8))
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.vertical, 6)
    }
}

// MARK: - AppKit Text Field without AutoFill

final class NoAutoFillTextField: NSTextField {
    @objc func _isPasswordAutofillEnabled() -> Bool {
        return false
    }

    override var allowsVibrancy: Bool { true }
}

struct SearchFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    var isFocused: Bool
    var onSubmit: () -> Void
    var onTab: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onTab: onTab)
    }

    func makeNSView(context: Context) -> NoAutoFillTextField {
        let tf = NoAutoFillTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        tf.textColor = .labelColor
        tf.isAutomaticTextCompletionEnabled = false
        tf.delegate = context.coordinator
        return tf
    }

    func updateNSView(_ nsView: NoAutoFillTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if isFocused {
            DispatchQueue.main.async {
                if nsView.window?.firstResponder != nsView.currentEditor() {
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onSubmit: () -> Void
        var onTab: () -> Bool

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onTab: @escaping () -> Bool) {
            self._text = text
            self.onSubmit = onSubmit
            self.onTab = onTab
        }

        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                self.text = tf.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return onTab()
            }
            return false
        }
    }
}
