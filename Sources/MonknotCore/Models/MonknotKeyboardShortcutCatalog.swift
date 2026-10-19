import Foundation

public struct MonknotKeyboardShortcutHelpEntry: Equatable, Sendable {
    public let title: String
    public let shortcut: String

    public init(title: String, shortcut: String) {
        self.title = title
        self.shortcut = shortcut
    }
}

public struct MonknotKeyboardShortcutSection: Equatable, Sendable {
    public let title: String
    public let entries: [MonknotKeyboardShortcutHelpEntry]

    public init(title: String, entries: [MonknotKeyboardShortcutHelpEntry]) {
        self.title = title
        self.entries = entries
    }
}

/// Every user-facing shortcut, grouped the way the reference shows them. Modifiers and named keys use
/// Apple's symbols (⌘ ⇧ ⌥ ⌃ ↩ ⇥ −); Escape is written "Esc", as macOS help does.
public enum MonknotKeyboardShortcutCatalog {
    private typealias Entry = MonknotKeyboardShortcutHelpEntry

    public static let sections: [MonknotKeyboardShortcutSection] = [
        MonknotKeyboardShortcutSection(title: "Files", entries: [
            Entry(title: "Quick Open", shortcut: "⌘P"),
            Entry(title: "New Markdown", shortcut: "⌘N"),
            Entry(title: "Daily Note", shortcut: "⇧⌘N"),
            Entry(title: "New Folder", shortcut: "⌥⌘N"),
            Entry(title: "Save", shortcut: "⌘S"),
            Entry(title: "Save All", shortcut: "⌥⌘S"),
            Entry(title: "Close Tab", shortcut: "⌘W"),
            Entry(title: "Reopen Closed Tab", shortcut: "⇧⌘T"),
            Entry(title: "Pin or Unpin Tab", shortcut: "⇧⌘P"),
        ]),
        MonknotKeyboardShortcutSection(title: "Workspace", entries: [
            Entry(title: "Add Workspace", shortcut: "⌘O"),
            Entry(title: "Switch Workspace 1–9", shortcut: "⌃⌘1–9"),
            Entry(title: "Refresh Workspace", shortcut: "⌘R"),
            Entry(title: "Find in Workspace", shortcut: "⇧⌘F"),
            Entry(title: "Undo Workspace Replace", shortcut: "⌘Z"),
        ]),
        MonknotKeyboardShortcutSection(title: "Sidebar", entries: [
            Entry(title: "Rename Selected Item", shortcut: "↩"),
            Entry(title: "Duplicate Selected Items", shortcut: "⌘D"),
            Entry(title: "Move Selected Items to Trash", shortcut: "⌘⌫"),
            Entry(title: "Undo Move or Copy", shortcut: "⌘Z"),
            Entry(title: "Redo Move or Copy", shortcut: "⇧⌘Z"),
            Entry(title: "Select Item Above or Below", shortcut: "↑ ↓"),
            Entry(title: "Add Item Above or Below to Selection", shortcut: "⇧↑ ⇧↓"),
            Entry(title: "Open or Close Folder", shortcut: "→ ←"),
            Entry(title: "Close All Folders", shortcut: "⌘←"),
            Entry(title: "Open Selected Items", shortcut: "⌘↓"),
        ]),
        MonknotKeyboardShortcutSection(title: "Find", entries: [
            Entry(title: "Find in Document or Terminal", shortcut: "⌘F"),
            Entry(title: "Find Next", shortcut: "⌘G"),
            Entry(title: "Find Previous", shortcut: "⇧⌘G"),
        ]),
        MonknotKeyboardShortcutSection(title: "Writing", entries: [
            Entry(title: "Bold", shortcut: "⌘B"),
            Entry(title: "Italic", shortcut: "⌘I"),
            Entry(title: "Inline Code", shortcut: "⌘E"),
            Entry(title: "Link", shortcut: "⌘K"),
            Entry(title: "Go to Heading", shortcut: "⇧⌘O"),
            Entry(title: "Complete Wikilink after [[", shortcut: "⇥"),
            Entry(title: "Inspect Links", shortcut: "⌥⌘L"),
            Entry(title: "Copy Rendered Markdown", shortcut: "⌥⌘C"),
            Entry(title: "Show Writing Tools (macOS 15.2+)", shortcut: "⌃⌘R"),
        ]),
        MonknotKeyboardShortcutSection(title: "View", entries: [
            Entry(title: "Toggle Sidebar", shortcut: "⌃⌘S"),
            Entry(title: "Toggle Split Editor", shortcut: "⌘\\"),
            Entry(title: "Toggle Terminal", shortcut: "⌥⌘J"),
            Entry(title: "Toggle Terminal Fullscreen", shortcut: "⌃⌘↩"),
            Entry(title: "Zoom In", shortcut: "⌘+"),
            Entry(title: "Zoom Out", shortcut: "⌘−"),
            Entry(title: "Actual Size", shortcut: "⌘0"),
            Entry(title: "Dismiss Search or Overlay", shortcut: "Esc"),
        ]),
    ]
}
