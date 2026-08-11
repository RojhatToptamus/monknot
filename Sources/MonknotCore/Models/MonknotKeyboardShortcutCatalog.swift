import Foundation

public struct MonknotKeyboardShortcutHelpEntry: Equatable, Sendable {
    public let title: String
    public let shortcut: String

    public init(title: String, shortcut: String) {
        self.title = title
        self.shortcut = shortcut
    }
}

public enum MonknotKeyboardShortcutCatalog {
    public static let entries: [MonknotKeyboardShortcutHelpEntry] = [
        MonknotKeyboardShortcutHelpEntry(title: "Quick Open", shortcut: "⌘P"),
        MonknotKeyboardShortcutHelpEntry(title: "Daily Note", shortcut: "⇧⌘N"),
        MonknotKeyboardShortcutHelpEntry(title: "Go to Heading", shortcut: "⇧⌘O"),
        MonknotKeyboardShortcutHelpEntry(title: "Open Folder", shortcut: "⌘O"),
        MonknotKeyboardShortcutHelpEntry(title: "New Markdown", shortcut: "⌘N"),
        MonknotKeyboardShortcutHelpEntry(title: "Save", shortcut: "⌘S"),
        MonknotKeyboardShortcutHelpEntry(title: "Close Tab", shortcut: "⌘W"),
        MonknotKeyboardShortcutHelpEntry(title: "Refresh Workspace", shortcut: "⌘R"),
        MonknotKeyboardShortcutHelpEntry(title: "Find in Document", shortcut: "⌘F"),
        MonknotKeyboardShortcutHelpEntry(title: "Find in Workspace", shortcut: "⇧⌘F"),
        MonknotKeyboardShortcutHelpEntry(title: "Wikilink Autocomplete", shortcut: "Tab in [["),
        MonknotKeyboardShortcutHelpEntry(title: "Find Next", shortcut: "⌘G"),
        MonknotKeyboardShortcutHelpEntry(title: "Find Previous", shortcut: "⇧⌘G"),
        MonknotKeyboardShortcutHelpEntry(title: "Pin or Unpin Tab", shortcut: "⇧⌘P"),
        MonknotKeyboardShortcutHelpEntry(title: "Toggle Terminal", shortcut: "⌥⌘J"),
        MonknotKeyboardShortcutHelpEntry(title: "Toggle Sidebar", shortcut: "⌃⌘S"),
        MonknotKeyboardShortcutHelpEntry(title: "Toggle Split Editor", shortcut: "⌘\\"),
        MonknotKeyboardShortcutHelpEntry(title: "Copy Rendered Markdown", shortcut: "⌥⌘C"),
        MonknotKeyboardShortcutHelpEntry(title: "Undo Workspace Replace", shortcut: "⌘Z"),
        MonknotKeyboardShortcutHelpEntry(title: "Zoom In", shortcut: "⌘+"),
        MonknotKeyboardShortcutHelpEntry(title: "Zoom Out", shortcut: "⌘-"),
        MonknotKeyboardShortcutHelpEntry(title: "Actual Size", shortcut: "⌘0"),
        MonknotKeyboardShortcutHelpEntry(title: "Dismiss Search or Overlay", shortcut: "Esc")
    ]
}
