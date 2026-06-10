import Foundation
import MonknotCore

@MainActor
final class MarkdownSymbolQuickOpenState: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var query = ""
    @Published private(set) var matches: [MarkdownOutlineItem] = []
    @Published var focusSerial = 0

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
    }

    func setQuery(_ query: String, items: [MarkdownOutlineItem]) {
        guard query != self.query else { return }
        self.query = query
        refresh(items: items)
    }

    func refresh(items: [MarkdownOutlineItem]) {
        matches = MarkdownSymbolQuickOpenMatcher.rankedItems(query: query, items: items)
    }
}
