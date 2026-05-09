import Foundation
import MarkprevCore

@MainActor
final class WorkspaceSearchState: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var isSearching = false
    @Published private(set) var results: [WorkspaceSearchResult] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var query = ""
    @Published var focusSerial = 0

    private let service = WorkspaceSearchService()
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    var resultCountText: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Search text and PDF files"
        }

        if isSearching {
            return "Searching..."
        }

        return "\(results.count) result\(results.count == 1 ? "" : "s")"
    }

    func present(documents: [WorkspaceDocument]) {
        isPresented = true
        focusSerial += 1
        search(documents: documents)
    }

    func dismiss() {
        isPresented = false
        cancelSearch()
    }

    func setQuery(_ query: String, documents: [WorkspaceDocument]) {
        guard query != self.query else { return }
        self.query = query
        search(documents: documents)
    }

    func refresh(documents: [WorkspaceDocument]) {
        guard isPresented else { return }
        search(documents: documents)
    }

    private func search(documents: [WorkspaceDocument]) {
        searchGeneration += 1
        let generation = searchGeneration
        let query = query
        let snapshot = documents

        searchTask?.cancel()
        errorMessage = nil

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isSearching = false
            results = []
            return
        }

        isSearching = true
        searchTask = Task { [service] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
                let worker = Task.detached(priority: .utility) {
                    try service.search(query: query, documents: snapshot)
                }
                let matches = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == self.searchGeneration else { return }
                    self.results = matches
                    self.isSearching = false
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    guard generation == self.searchGeneration else { return }
                    self.results = []
                    self.errorMessage = error.localizedDescription
                    self.isSearching = false
                }
            }
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    deinit {
        searchTask?.cancel()
    }
}
