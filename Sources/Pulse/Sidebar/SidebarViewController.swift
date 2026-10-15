import AppKit

/// Files, Search and Source Control, switched by a small segmented control in the header
/// row level with the tabs.
final class SidebarViewController: NSViewController {
    let fileTree = FileTreeController()
    let searchPanel = SearchPanelController()
    let sourceControl = SourceControlPanel()

    private let modeControl = NSSegmentedControl()
    private let container = NSView()

    override func loadView() {
        let root = NSView()

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
        display(fileTree)
    }

    func showSearch(seed: String?) {
        modeControl.selectedSegment = 1
        display(searchPanel)
        searchPanel.focus(with: seed)
    }

    func showSourceControl() {
        modeControl.selectedSegment = 2
        display(sourceControl)
    }
}
