import AppKit

/// The open file's path under the tabs, like VS Code's breadcrumbs:
/// "src › pages › Button › styles.module.scss", from the opened folder.
/// One label; the background is the layer's color (no backing store).
final class BreadcrumbBar: NSView {
    static let height: CGFloat = 22

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingHead   // a long path keeps its file name
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.editorBackground.cgColor
        }
    }

    /// The path parts shown for `file`: from `root` when the file is inside
    /// it, otherwise from the home folder ("~") or the disk root.
    static func segments(for file: URL, root: URL?) -> [String] {
        let path = file.standardizedFileURL.path
        if let root = root?.standardizedFileURL.path {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) {
                return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path.hasPrefix(home + "/") {
            return ["~"] + path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        }
        return path.split(separator: "/").map(String.init)
    }

    /// Shows `file`'s path (nil clears it). The editor hides the bar when empty.
    func show(_ file: URL?, root: URL?) {
        guard let file else {
            label.attributedStringValue = NSAttributedString()
            toolTip = nil
            return
        }
        let parts = BreadcrumbBar.segments(for: file, root: root)
        let font = NSFont.systemFont(ofSize: 12)
        let text = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: "  ›  ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            let isFile = index == parts.count - 1
            text.append(NSAttributedString(string: part, attributes: [
                .font: font, .foregroundColor: isFile ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]))
        }
        label.attributedStringValue = text
        toolTip = file.path
        setAccessibilityLabel("Path: " + parts.joined(separator: ", "))
    }

    /// The path as shown, for tests.
    var text: String { label.stringValue }
}
