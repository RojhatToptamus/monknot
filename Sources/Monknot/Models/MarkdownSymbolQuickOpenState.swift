import Foundation
import MonknotCore

@MainActor
final class MarkdownSymbolQuickOpenState: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var query = ""
    @Published private(set) var matches: [MarkdownOutlineItem] = []
    @Published var focusSerial = 0
    /// The row Return opens; moved with ↑/↓ while the search field keeps focus.
    @Published private(set) var selectedIndex = 0

    var selectedMatch: MarkdownOutlineItem? {
        matches.indices.contains(selectedIndex) ? matches[selectedIndex] : nil
    }

    func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + offset), matches.count - 1)
    }

    func present(items: [MarkdownOutlineItem]) {
        isPresented = true
        query = ""
        focusSerial += 1
        refresh(items: items)
    }

    func dismiss() {
        isPresented = false
        query = ""
        matches = []
        selectedIndex = 0
    }

    func setQuery(_ query: String, items: [MarkdownOutlineItem]) {
        guard query != self.query else { return }
        self.query = query
        refresh(items: items)
    }

    func refresh(items: [MarkdownOutlineItem]) {
        matches = MarkdownSymbolQuickOpenMatcher.rankedItems(query: query, items: items)
        selectedIndex = 0
    }
}
