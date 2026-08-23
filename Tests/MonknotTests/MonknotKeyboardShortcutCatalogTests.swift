import MonknotCore
import XCTest

final class MonknotKeyboardShortcutCatalogTests: XCTestCase {
    func testCatalogMatchesTheCompleteUserFacingShortcutTable() {
        let expected: [MonknotKeyboardShortcutHelpEntry] = [
            .init(title: "Quick Open", shortcut: "⌘P"),
            .init(title: "Daily Note", shortcut: "⇧⌘N"),
            .init(title: "Go to Heading", shortcut: "⇧⌘O"),
            .init(title: "Add Workspace", shortcut: "⌘O"),
            .init(title: "Switch Workspace 1–9", shortcut: "⌃⌘1–9"),
            .init(title: "New Markdown", shortcut: "⌘N"),
            .init(title: "Save", shortcut: "⌘S"),
            .init(title: "Save All", shortcut: "⌥⌘S"),
            .init(title: "Close Tab", shortcut: "⌘W"),
            .init(title: "Reopen Closed Tab", shortcut: "⇧⌘T"),
            .init(title: "Refresh Workspace", shortcut: "⌘R"),
            .init(title: "Find in Document or Terminal", shortcut: "⌘F"),
            .init(title: "Find in Workspace", shortcut: "⇧⌘F"),
            .init(title: "Complete Wikilink after [[", shortcut: "Tab"),
            .init(title: "Find Next", shortcut: "⌘G"),
            .init(title: "Find Previous", shortcut: "⇧⌘G"),
            .init(title: "Pin or Unpin Tab", shortcut: "⇧⌘P"),
            .init(title: "Toggle Terminal", shortcut: "⌥⌘J"),
            .init(title: "Toggle Terminal Fullscreen", shortcut: "⌃⌘↩"),
            .init(title: "Toggle Sidebar", shortcut: "⌃⌘S"),
            .init(title: "Toggle Split Editor", shortcut: "⌘\\"),
            .init(title: "Show Writing Tools (macOS 15.2+)", shortcut: "⌃⌘R"),
            .init(title: "Inspect Links", shortcut: "⌥⌘L"),
            .init(title: "Copy Rendered Markdown", shortcut: "⌥⌘C"),
            .init(title: "Undo Workspace Replace", shortcut: "⌘Z"),
            .init(title: "Zoom In", shortcut: "⌘+"),
            .init(title: "Zoom Out", shortcut: "⌘-"),
            .init(title: "Actual Size", shortcut: "⌘0"),
            .init(title: "Dismiss Search or Overlay", shortcut: "Esc"),
        ]

        XCTAssertEqual(MonknotKeyboardShortcutCatalog.entries, expected)
    }

    func testCatalogTitlesAreUnique() {
        let titles = MonknotKeyboardShortcutCatalog.entries.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func testCatalogDoesNotAdvertiseUnroutedQuestionMarkOrTerminalPasteActions() {
        XCTAssertFalse(MonknotKeyboardShortcutCatalog.entries.contains {
            $0.shortcut == "?" || $0.title == "Keyboard Shortcuts Help"
        })
        XCTAssertFalse(MonknotKeyboardShortcutCatalog.entries.contains {
            $0.title == "Paste Selection into Terminal"
        })
    }
}
