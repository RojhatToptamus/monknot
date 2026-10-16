import MonknotCore
import XCTest

final class MonknotKeyboardShortcutCatalogTests: XCTestCase {
    func testCatalogMatchesTheCompleteUserFacingShortcutTable() {
        let expected: [String: [MonknotKeyboardShortcutHelpEntry]] = [
            "Files": [
                .init(title: "Quick Open", shortcut: "⌘P"),
                .init(title: "New Markdown", shortcut: "⌘N"),
                .init(title: "Daily Note", shortcut: "⇧⌘N"),
                .init(title: "New Folder", shortcut: "⌥⌘N"),
                .init(title: "Save", shortcut: "⌘S"),
                .init(title: "Save All", shortcut: "⌥⌘S"),
                .init(title: "Close Tab", shortcut: "⌘W"),
                .init(title: "Reopen Closed Tab", shortcut: "⇧⌘T"),
                .init(title: "Pin or Unpin Tab", shortcut: "⇧⌘P"),
            ],
            "Workspace": [
                .init(title: "Add Workspace", shortcut: "⌘O"),
                .init(title: "Switch Workspace 1–9", shortcut: "⌃⌘1–9"),
                .init(title: "Refresh Workspace", shortcut: "⌘R"),
                .init(title: "Find in Workspace", shortcut: "⇧⌘F"),
                .init(title: "Undo Workspace Replace", shortcut: "⌘Z"),
            ],
            "Sidebar": [
                .init(title: "Rename Selected Item", shortcut: "↩"),
                .init(title: "Duplicate Selected Item", shortcut: "⌘D"),
                .init(title: "Move Selected Item to Trash", shortcut: "⌘⌫"),
            ],
            "Find": [
                .init(title: "Find in Document or Terminal", shortcut: "⌘F"),
                .init(title: "Find Next", shortcut: "⌘G"),
                .init(title: "Find Previous", shortcut: "⇧⌘G"),
            ],
            "Writing": [
                .init(title: "Go to Heading", shortcut: "⇧⌘O"),
                .init(title: "Complete Wikilink after [[", shortcut: "⇥"),
                .init(title: "Inspect Links", shortcut: "⌥⌘L"),
                .init(title: "Copy Rendered Markdown", shortcut: "⌥⌘C"),
                .init(title: "Show Writing Tools (macOS 15.2+)", shortcut: "⌃⌘R"),
            ],
            "View": [
                .init(title: "Toggle Sidebar", shortcut: "⌃⌘S"),
                .init(title: "Toggle Split Editor", shortcut: "⌘\\"),
                .init(title: "Toggle Terminal", shortcut: "⌥⌘J"),
                .init(title: "Toggle Terminal Fullscreen", shortcut: "⌃⌘↩"),
                .init(title: "Zoom In", shortcut: "⌘+"),
                .init(title: "Zoom Out", shortcut: "⌘−"),
                .init(title: "Actual Size", shortcut: "⌘0"),
                .init(title: "Dismiss Search or Overlay", shortcut: "Esc"),
            ],
        ]

        XCTAssertEqual(
            MonknotKeyboardShortcutCatalog.sections.map(\.title),
            ["Files", "Workspace", "Sidebar", "Find", "Writing", "View"]
        )
        for section in MonknotKeyboardShortcutCatalog.sections {
            XCTAssertEqual(section.entries, expected[section.title], section.title)
        }
        XCTAssertEqual(MonknotKeyboardShortcutCatalog.entries.count, 33)
    }

    func testShortcutsUseAppleKeySymbolsRatherThanWordsOrAscii() {
        for entry in MonknotKeyboardShortcutCatalog.entries {
            XCTAssertFalse(entry.shortcut.contains("Tab"), entry.title)
            XCTAssertFalse(entry.shortcut.hasSuffix("-"), "\(entry.title) uses an ASCII hyphen for minus")
        }
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
