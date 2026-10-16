import AppKit

struct TabInfo {
    let title: String
    let tooltip: String?
    let isDirty: Bool
}

/// A flat row of tabs just below the title bar. Empty space in
/// the bar drags the window, like a normal title bar.
final class TabBarView: NSView {
    static let height: CGFloat = 38

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// The right-click menu for a tab (Split Right, Split Down, Close…).
    var menuForTab: ((Int) -> NSMenu?)?

    private var items: [TabItemView] = []

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// `isActive`: false for a split pane without focus, whose selected tab
    /// is then drawn like the others.
    func update(tabs: [TabInfo], selected: Int?, isActive: Bool = true) {
        while items.count > tabs.count { items.removeLast().removeFromSuperview() }
        while items.count < tabs.count {
            let item = TabItemView()
            item.bar = self
            addSubview(item)
            items.append(item)
        }
        for (index, tab) in tabs.enumerated() {
            items[index].configure(tab: tab, index: index, selected: index == selected, current: isActive)
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let available = max(0, bounds.width - 8)
        let width = items.isEmpty ? 0 : min(200, max(96, available / CGFloat(items.count)))
        var x: CGFloat = 0
        for item in items {
            item.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chromeBackground.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

final class TabItemView: NSView {
    weak var bar: TabBarView?
    private(set) var index = 0
    private var selected = false
    private var dirty = false
    private var hovering = false
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .left
        addSubview(label)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(tab: TabInfo, index: Int, selected: Bool, current: Bool = true) {
        self.index = index
        self.selected = selected
        self.dirty = tab.isDirty
        label.stringValue = tab.title
        label.textColor = selected && current ? .labelColor : .secondaryLabelColor
        toolTip = tab.tooltip
        setAccessibilityLabel(tab.title + (tab.isDirty ? ", edited" : ""))
        setAccessibilityValue(selected)
        refreshCloseButton()
        needsDisplay = true
    }

    private func refreshCloseButton() {
        closeButton.isHidden = !(hovering || (selected && !dirty))
    }

    override func layout() {
        super.layout()
        let height = bounds.height - 1
        closeButton.frame = NSRect(x: bounds.width - 26, y: (height - 18) / 2, width: 18, height: 18)
        let labelHeight = label.intrinsicContentSize.height
        label.frame = NSRect(x: 14, y: (height - labelHeight) / 2, width: max(0, bounds.width - 14 - 30), height: labelHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            Theme.editorBackground.setFill()
            bounds.fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 9, width: 1, height: bounds.height - 18).fill()
        if dirty && !hovering {
            NSColor.secondaryLabelColor.setFill()
            let height = bounds.height - 1
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 20.5, y: height / 2 - 3.5, width: 7, height: 7)).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshCloseButton()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshCloseButton()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        bar?.onSelect?(index)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        bar?.menuForTab?(index)
    }

    override func otherMouseDown(with event: NSEvent) {
        bar?.onClose?(index)
    }

    @objc private func closeClicked() {
        bar?.onClose?(index)
    }
}
