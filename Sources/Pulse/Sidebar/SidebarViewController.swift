import AppKit

/// Files, Search and Source Control, switched by a small segmented control.
/// Like VS Code's side bar: a flush column in the chrome color, with a header
/// row ("EXPLORER") exactly as tall as the tab row beside it.
final class SidebarViewController: NSViewController {
    let fileTree = FileTreeController()
    let searchPanel = SearchPanelController()
    let sourceControl = SourceControlPanel()

    private let modeControl = NSSegmentedControl()
    private let headerTitle = NSTextField(labelWithString: "EXPLORER")
    private let container = NSView()

    override func loadView() {
        let root = ChromeBackgroundView()

        headerTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        headerTitle.textColor = .secondaryLabelColor
        headerTitle.lineBreakMode = .byTruncatingTail
        headerTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerTitle)

        modeControl.segmentCount = 3
        modeControl.trackingMode = .selectOne
        modeControl.setImage(NSImage(systemSymbolName: "folder", accessibilityDescription: "Files"), forSegment: 0)
        modeControl.setImage(NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search"), forSegment: 1)
        modeControl.setToolTip("Files", forSegment: 0)
        modeControl.setImage(NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Source Control"), forSegment: 2)
        modeControl.setToolTip("Search (⇧⌘F)", forSegment: 1)
        modeControl.setToolTip("Source Control (⌃⇧G)", forSegment: 2)
        modeControl.selectedSegment = 0
        modeControl.controlSize = .small
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(modeControl)

        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)

        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: modeControl.leadingAnchor, constant: -8),
            headerTitle.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            modeControl.centerYAnchor.constraint(equalTo: root.topAnchor, constant: TabBarView.height / 2),
            modeControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: root.topAnchor, constant: TabBarView.height),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        addChild(fileTree)
        addChild(searchPanel)
        addChild(sourceControl)
        display(fileTree)
    }

    /// View › Font Size › Sidebar, for all three panels.
    func applyFontSize() {
        fileTree.applyFontSize()
        searchPanel.applyFontSize()
        sourceControl.applyFontSize()
    }

    private func display(_ child: NSViewController) {
        container.subviews.forEach { $0.removeFromSuperview() }
        child.view.frame = container.bounds
        child.view.autoresizingMask = [.width, .height]
        container.addSubview(child.view)
    }

    @objc private func modeChanged() {
        switch modeControl.selectedSegment {
        case 1: showSearch(seed: nil)
        case 2: showSourceControl()
        default: showFiles()
        }
    }

    func showFiles() {
        modeControl.selectedSegment = 0
        headerTitle.stringValue = "EXPLORER"
        display(fileTree)
    }

    func showSearch(seed: String?) {
        modeControl.selectedSegment = 1
        headerTitle.stringValue = "SEARCH"
        display(searchPanel)
        searchPanel.focus(with: seed)
    }

    func showSourceControl() {
        modeControl.selectedSegment = 2
        headerTitle.stringValue = "SOURCE CONTROL"
        display(sourceControl)
    }
}

/// The sidebar's surface: the same chrome color as the tab bar, set as a layer
/// color so it needs no backing store.
private final class ChromeBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.chromeBackground.cgColor
        }
    }
}
