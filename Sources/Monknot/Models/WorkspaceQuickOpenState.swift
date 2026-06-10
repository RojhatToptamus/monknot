import Foundation
import MonknotCore

@MainActor
final class WorkspaceQuickOpenState: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var query = ""
    @Published private(set) var matches: [WorkspaceDocument] = []
    @Published var focusSerial = 0

    func present(documents: [WorkspaceDocument]) {
        isPresented = true
        query = ""
        focusSerial += 1
        refresh(documents: documents)
    }

    func dismiss() {
        isPresented = false
        query = ""
        matches = []
    }

    func setQuery(_ query: String, documents: [WorkspaceDocument]) {
        guard query != self.query else { return }
        self.query = query
        refresh(documents: documents)
    }

    func refresh(documents: [WorkspaceDocument]) {
        matches = WorkspaceQuickOpenMatcher.rankedDocuments(query: query, documents: documents)
    }
}
