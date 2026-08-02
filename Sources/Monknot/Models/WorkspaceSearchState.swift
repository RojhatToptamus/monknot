import Foundation
import MonknotCore

@MainActor
final class WorkspaceSearchState: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var isSearching = false
    @Published private(set) var results: [WorkspaceSearchResult] = []
    @Published private(set) var selectedResultIndex = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var skippedLargeFileCount = 0
    @Published private(set) var query = ""
    @Published var replaceText = ""
    @Published var replaceScope: WorkspaceReplaceScope = .entireWorkspace
    @Published private(set) var replaceStatusMessage: String?
    @Published var focusSerial = 0

    var replaceableSearchResultDocumentIDs: Set<String> {
        Set(
            results
                .filter { $0.kind == .text }
                .map(\.documentID)
        )
    }

    var replaceScopeDocumentIDs: Set<String> {
        switch replaceScope {
        case .entireWorkspace:
            return []
        case .searchResultsOnly:
            return replaceableSearchResultDocumentIDs
        case .selectedSearchResult:
            guard let selectedResult, selectedResult.kind == .text else { return [] }
            return [selectedResult.documentID]
        }
    }

    var canReplaceInCurrentScope: Bool {
        switch replaceScope {
        case .entireWorkspace:
            return true
        case .searchResultsOnly:
            return !replaceableSearchResultDocumentIDs.isEmpty
        case .selectedSearchResult:
            return selectedResult?.kind == .text
        }
    }

    private let service = WorkspaceSearchService()
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    func present(documents: [WorkspaceDocument]) {
        isPresented = true
        focusSerial += 1
        search(documents: documents)
    }

    func dismiss() {
        isPresented = false
        cancelSearch()
        selectedResultIndex = 0
        replaceStatusMessage = nil
    }

    func setReplaceText(_ text: String) {
        replaceText = text
        replaceStatusMessage = nil
    }

    func clearReplaceStatus() {
        replaceStatusMessage = nil
    }

    func setReplaceStatusMessage(_ message: String?) {
        replaceStatusMessage = message
    }

    func selectNextResult() {
        guard !results.isEmpty else { return }
        selectedResultIndex = (selectedResultIndex + 1) % results.count
    }

    func selectPreviousResult() {
        guard !results.isEmpty else { return }
        selectedResultIndex = (selectedResultIndex - 1 + results.count) % results.count
    }

    func selectResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        selectedResultIndex = index
    }

    var selectedResult: WorkspaceSearchResult? {
        guard !results.isEmpty else { return nil }
        let index = min(max(selectedResultIndex, 0), results.count - 1)
        return results[index]
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
        skippedLargeFileCount = 0

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if isSearching {
                isSearching = false
            }
            if !results.isEmpty {
                results = []
            }
            if selectedResultIndex != 0 {
                selectedResultIndex = 0
            }
            return
        }

        isSearching = true
        searchTask = Task { [service] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
                let worker = Task.detached(priority: .utility) {
                    try service.search(query: query, documents: snapshot)
                }
                let batch = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == self.searchGeneration else { return }
                    self.results = batch.results
                    self.skippedLargeFileCount = batch.skippedLargeFileCount
                    self.selectedResultIndex = 0
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
