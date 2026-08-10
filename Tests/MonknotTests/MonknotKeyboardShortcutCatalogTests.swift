import XCTest
import MonknotCore

final class MonknotKeyboardShortcutCatalogTests: XCTestCase {
    func testQuickOpenShortcutIsListed() {
        let entry = MonknotKeyboardShortcutCatalog.entries.first { $0.title == "Quick Open" }
        XCTAssertEqual(entry?.shortcut, "⌘P")
    }

    func testNewExplicitClipboardAndTerminalActionsAreListed() {
        XCTAssertEqual(
            MonknotKeyboardShortcutCatalog.entries.first {
                $0.title == "Copy Rendered Markdown"
            }?.shortcut,
            "⌥⌘C"
        )
        XCTAssertEqual(
            MonknotKeyboardShortcutCatalog.entries.first {
                $0.title == "Paste Selection into Terminal"
            }?.shortcut,
            "⌃⌥⌘V"
        )
    }
}
