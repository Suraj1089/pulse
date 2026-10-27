import AppKit
import XCTest
@testable import Pulse

/// Go to Definition (F12, ⌘-click): the name is looked up in its own file,
/// then in the folder's files of its language by ripgrep, git grep or the
/// built-in scan. One place opens; several, or none, show a menu.
final class DefinitionTests: PulseTestCase {
    private static let files = [
        "orders/service.py": """
            from orders.pricing import calculate_total


            class OrderService:
                def place_order(self, items):
                    total = calculate_total(items)
                    order = Order(items, total)
                    order.save()
                    order.refund()
                    return total
            """,
        "orders/pricing.py": """
            TAX = 0.18


            def calculate_total(items):
                return sum(items) * (1 + TAX)
            """,
        "orders/models.py": """
            class Order:
                def save(self):
                    pass
            """,
        "payments/models.py": """
            class Payment:
                def save(self):
                    pass
            """,
        "notes.md": "def save(self):\n",
    ]

    private func project() throws -> (URL, MainWindowController) {
        let root = try makeFolder(files: DefinitionTests.files)
        let controller = makeController(opening: [root, root.appendingPathComponent("orders/service.py")])
        // Let the event that opened the file end (see EditorViewController.settling).
        spin(0.02)
        return (root, controller)
    }

    /// Puts the caret inside the first `word` on one-based `line` of the active file.
    private func putCaret(in word: String, line: Int, of editor: EditorViewController) throws {
        let document = try XCTUnwrap(editor.activeDocument)
        let text = document.storage.string as NSString
        let lineRange = text.lineRange(for: NSRange(location: document.start(ofLine: line - 1), length: 0))
        let found = text.range(of: word, options: .literal, range: lineRange)
        XCTAssertNotEqual(found.location, NSNotFound, "\(word) on line \(line)")
        editor.textView.setSelectedRange(NSRange(location: found.location + 1, length: 0))
    }

    /// The active file, the selection's one-based line and the selected text.
    private func selection(_ editor: EditorViewController) -> String {
        guard let document = editor.activeDocument else { return "none" }
        let range = editor.textView.selectedRange()
        let text = (document.storage.string as NSString).substring(with: range)
        return "\(document.url?.path.components(separatedBy: "/project/").last ?? "?"):\(document.line(at: range.location) + 1):\(text)"
    }

    func testOneDefinitionOpensWithTheNameSelectedAndBackReturns() throws {
        let (_, controller) = try project()
        let editor = controller.editor
        try putCaret(in: "calculate_total", line: 6, of: editor)
        XCTAssertTrue(editor.canGoToDefinition)
        controller.goToDefinition(nil)
        wait("the definition") { editor.activeDocument?.displayName == "pricing.py" }
        XCTAssertEqual(selection(editor), "orders/pricing.py:4:calculate_total", "the import on line 1 is not a definition")
        XCTAssertNil(editor.definitionSearch, "nothing is kept once the search has answered")

        controller.goBack(nil)
        XCTAssertEqual(editor.activeDocument?.displayName, "service.py")
        XCTAssertEqual(editor.activeDocument?.line(at: editor.textView.selectedRange().location), 5)
    }

    func testALocalIsFoundInItsOwnFile() throws {
        let (_, controller) = try project()
        let editor = controller.editor
        try putCaret(in: "total", line: 10, of: editor)
        controller.goToDefinition(nil)
        wait("the local") { editor.definitionSearch == nil && editor.textView.selectedRange().length > 0 }
        XCTAssertEqual(selection(editor), "orders/service.py:6:total")
        XCTAssertTrue(editor.canGoBack, "even a jump of a few lines can be gone back from")
    }

    func testSeveralDefinitionsShowAMenuNearestFirstThatGoesWhenItCloses() throws {
        let (_, controller) = try project()
        let editor = controller.editor
        var shown: NSMenu?
        editor.presentDefinitionMenu = { menu, _, _ in shown = menu }
        try putCaret(in: "save", line: 8, of: editor)
        controller.goToDefinition(nil)
        wait("the menu") { shown != nil }
        XCTAssertEqual(shown?.items.filter { !$0.isSeparatorItem }.map(\.title), [
            "2 definitions of “save”",
            "Same Folder", "def save(self):  orders/models.py:2",
            "Other Files", "def save(self):  payments/models.py:2",
            "Find “save” in Project",
        ], "Markdown files are not searched")

        let payments = try XCTUnwrap(shown?.items.firstIndex { $0.title.hasSuffix("payments/models.py:2") })
        weak var closed: NSMenu?
        autoreleasepool {
            closed = shown
            shown?.performActionForItem(at: payments)
            shown = nil
        }
        XCTAssertEqual(selection(editor), "payments/models.py:2:save")
        XCTAssertNil(closed, "the menu and its places are freed once it closes")
        XCTAssertNil(editor.definitionSearch)
    }

    func testNoDefinitionSaysSoAndOffersFindInProject() throws {
        let (_, controller) = try project()
        let editor = controller.editor
        var shown: NSMenu?
        editor.presentDefinitionMenu = { menu, _, _ in shown = menu }
        try putCaret(in: "refund", line: 9, of: editor)
        controller.goToDefinition(nil)
        wait("the menu") { shown != nil }
        XCTAssertEqual(shown?.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["No definition of “refund” in this folder", "Find “refund” in Project"])
        XCTAssertEqual(editor.activeDocument?.displayName, "service.py")
    }

    func testCommandClickOnANameGoesToItsDefinition() throws {
        let (_, controller) = try project()
        let editor = controller.editor
        let textView = try XCTUnwrap(editor.textView)
        let text = textView.string as NSString
        let call = text.range(of: "calculate_total(items)")
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: call.location + 3, length: 1), actualCharacterRange: nil)
        let container = try XCTUnwrap(textView.textContainer)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let point = NSPoint(x: rect.midX + textView.textContainerOrigin.x, y: rect.midY + textView.textContainerOrigin.y)

        // A ⌘-click: the mouse-up is queued first, as the click is read ahead to it.
        let window = try XCTUnwrap(textView.window)
        let location = textView.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        textView.mouseDown(with: event(.leftMouseDown))
        wait("the definition") { editor.activeDocument?.displayName == "pricing.py" }
        XCTAssertEqual(selection(editor), "orders/pricing.py:4:calculate_total")
    }

    func testF12AndOnlyLanguagesWithPatterns() throws {
        KeyBindings.register(MainMenu.build())
        let command = try XCTUnwrap(KeyBindings.command(id: "go.goToDefinition"))
        XCTAssertEqual(command.defaultShortcut?.config, "f12")
        let (root, controller) = try project()
        XCTAssertTrue(controller.validateMenuItem(command.item))
        controller.editor.open(root.appendingPathComponent("notes.md"))
        XCTAssertFalse(controller.validateMenuItem(command.item), "Markdown has no definitions")
    }

    // MARK: Searching

    func testRipgrepGitAndTheBuiltInScanFindTheSamePlaces() throws {
        let root = try makeFolder(files: DefinitionTests.files)
        if GitStatus.git != nil { try git("init", in: root) }
        let language = Language.python
        let pattern = try XCTUnwrap(language.definitionPattern(for: "save", withLocals: false))
        let index = FileIndex(root: root)
        var modes = [("built-in scan", false, false)]
        if GitStatus.git != nil { modes.append(("git grep", false, true)) }
        if ProjectSearch.ripgrep != nil { modes.append(("ripgrep", true, false)) }
        for (label, ripgrep, git) in modes {
            let search = ProjectSearch()
            var found: [Definition]?
            search.findDefinitions(of: "save", pattern: pattern, extensions: language.extensions, root: root, index: index,
                                   useRipgrep: ripgrep, useGit: git) { found = $0 }
            wait(label) { found != nil }
            XCTAssertEqual((found ?? []).map { "\($0.path):\($0.line):\($0.column):\($0.preview)" }.sorted(),
                           ["orders/models.py:2:8:def save(self):", "payments/models.py:2:8:def save(self):"], label)
        }
    }

    /// The patterns as NSRegularExpression reads them: the file being edited
    /// is searched by it, and it decides where the name is on every line a
    /// tool finds. Each case lists the one-based lines that define the name
    /// anywhere, then those that count only in its own file (locals).
    func testEachLanguagesPatternsFindItsDefinitions() throws {
        let cases: [(Language, String, String, Set<Int>, Set<Int>)] = [
            (.python, "calculate_total", """
                from orders.pricing import calculate_total
                def calculate_total(items, discount=None) -> Decimal:
                    total = calculate_total(items)
                async def calculate_total():
                calculate_total = 5
                x = calculate_total
                class calculate_total_x:
                """, [2, 4, 5], []),
            (.python, "total", """
                TOTAL = 1
                total = 0
                total: int = 5
                def f():
                        total = 1
                    total == 2
                        self.total = 3
                    for total in items:
                    with open(x) as total:
                    total += 1
                """, [2, 3, 7], [5, 8, 9]),
            (.swift, "reveal", """
                    func reveal(_ range: NSRange) {
                    @objc private func reveal(line: Int) {
                    private(set) var reveal = 1
                        reveal(range)
                    override public func reveal<T>(x: T) {
                final class reveal {
                            let reveal = 5
                        guard let reveal = x else { return }
                    case reveal(String)
                    func revealAll() {
                """, [1, 2, 3, 5, 6, 9], [7, 8]),
            (.javascript, "save", """
                export function save(item) {
                export default async function save() {
                const save = (x) => x
                  save(item) {
                  async save(item: Item): Promise<void> {
                  save(item);
                        let save = 1
                for (const save of list) {
                class Save {}
                export class save {}
                """, [1, 2, 3, 4, 5, 10], [7, 8]),
            (.go, "Parse", """
                func Parse(s string) error {
                func (p *Parser) Parse() error {
                type Parse struct {
                \tParse(x)
                var Parse = 1
                \tx, Parse := f()
                \tParse := 2
                """, [1, 2, 3, 5], [6, 7]),
            (.rust, "parse", """
                pub fn parse(s: &str) {
                pub(crate) async fn parse() {
                    let parse = 1;
                    let mut parse = 2;
                struct parse;
                macro_rules! parse {
                    parse(x);
                """, [1, 2, 5, 6], [3, 4]),
            (.cFamily, "parse_args", """
                static int parse_args(int argc, char **argv)
                int parse_args(int argc, char **argv);
                #define parse_args(x) x
                    parse_args(argc, argv);
                } parse_args;
                struct parse_args {
                void Foo::parse_args(int x) const {
                - (void)parse_args:(int)x {
                """, [1, 3, 5, 6, 7, 8], []),
            (.java, "save", """
                    public void save(Item item) {
                    public abstract class save {
                    private int save = 5;
                    private String save;
                        save(item);
                        int save = 3;
                    fun save(x: Int) {
                    fun Order.save() {
                    val save = 1
                        val save = 2
                        return save(x);
                """, [1, 2, 3, 4, 7, 8, 9], [6, 10]),
            (.ruby, "save", """
                  def save(x)
                  def self.save
                  class Save
                SAVE = 1
                save = 2
                  attr_accessor :name, :save
                    save(x)
                    save == 3
                        save = 4
                """, [1, 2, 5, 6], [9]),
            (.shell, "build", """
                build() {
                function build {
                function build() {
                build=1
                export build=2
                  build
                local build=3
                """, [1, 2, 3, 4, 5, 7], []),
        ]
        for (language, name, source, everywhere, localOnly) in cases {
            let text = source as NSString
            for withLocals in [false, true] {
                let pattern = try XCTUnwrap(language.definitionPattern(for: name, withLocals: withLocals), language.name)
                let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
                let lines = ProjectSearch.definitionRanges(of: name, in: text, regex: regex, limit: 50).map { range in
                    text.substring(to: range.location).filter { $0 == "\n" }.count + 1
                }
                XCTAssertEqual(Set(lines), withLocals ? everywhere.union(localOnly) : everywhere,
                               "\(language.name) \(name), locals: \(withLocals)")
                XCTAssertEqual(lines.count, Set(lines).count, "\(language.name): one place a line")
            }
        }
    }
}
