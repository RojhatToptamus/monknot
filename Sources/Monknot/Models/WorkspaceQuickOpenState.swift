import Foundation
import MonknotCore

@MainActor
final class WorkspaceQuickOpenState: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var query = ""
    @Published private(set) var matches: [WorkspaceDocument] = []
    @Published var focusSerial = 0
    /// The row Return opens; moved with ↑/↓ while the search field keeps focus.
    @Published private(set) var selectedIndex = 0

    var selectedMatch: WorkspaceDocument? {
        matches.indices.contains(selectedIndex) ? matches[selectedIndex] : nil
    }

    func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + offset), matches.count - 1)
    }

    func present(documents: [WorkspaceDocument]) {
        isPresented = true
        query = ""
        focusSerial += 1
        refresh(documents: documents)
        selectedIndex = 0
    }

    func dismiss() {
        isPresented = false
        query = ""
        matches = []
        selectedIndex = 0
    }

    func setQuery(_ query: String, documents: [WorkspaceDocument]) {
        guard query != self.query else { return }
        self.query = query
        refresh(documents: documents)
        selectedIndex = 0
    }

    /// Workspace changes re-rank the list while it is open; the chosen file
    /// stays chosen so Return never opens a row the user did not pick.
    func refresh(documents: [WorkspaceDocument]) {
        let selectedID = selectedMatch?.id
        matches = WorkspaceQuickOpenMatcher.rankedDocuments(query: query, documents: documents)
        selectedIndex = selectedID.flatMap { id in matches.firstIndex { $0.id == id } } ?? 0
    }
}
