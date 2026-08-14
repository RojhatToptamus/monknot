import Foundation
import MonknotCore

enum DocumentSearchDirection: String, Equatable {
    case next
    case previous
}

enum DocumentReplacementAction: Equatable {
    case current
    case all
}

struct DocumentReplacementRequest: Equatable {
    let serial: Int
    let documentID: String
    let query: String
    let replacement: String
    let action: DocumentReplacementAction
    let matchIndex: Int
    let options: MonknotSearchOptions
}

struct DocumentSearchResult: Equatable {
    var currentIndex: Int = 0
    var totalCount: Int = 0
}

struct DocumentSearchApplicationResult {
    let searchResult: DocumentSearchResult
    let consumedReplacementSerial: Int?
}

struct DocumentSearchState: Equatable {
    var isPresented = false
    var isReplacePresented = false
    var query = ""
    var replacement = ""
    var currentIndex = 0
    var totalCount = 0
    var navigationSerial = 0
    var navigationDirection: DocumentSearchDirection = .next
    var focusSerial = 0
    private(set) var replacementRequest: DocumentReplacementRequest?
    private var nextReplacementSerial = 0

    var effectiveQuery: String {
        isPresented ? query : ""
    }

    var countText: String {
        "\(currentIndex)/\(totalCount)"
    }

    mutating func present() {
        isPresented = true
        focusSerial += 1
    }

    mutating func dismiss() {
        isPresented = false
        isReplacePresented = false
        replacementRequest = nil
        updateResult(.init())
    }

    mutating func setQuery(_ nextQuery: String) {
        guard query != nextQuery else { return }
        query = nextQuery
        updateResult(.init())
    }

    mutating func setReplacement(_ nextReplacement: String) {
        replacement = nextReplacement
    }

    mutating func toggleReplace() {
        isReplacePresented.toggle()
    }

    mutating func replaceCurrent(
        in documentID: String,
        options: MonknotSearchOptions = MonknotSearchOptions()
    ) {
        enqueueReplacement(.current, in: documentID, options: options)
    }

    mutating func replaceAll(
        in documentID: String,
        options: MonknotSearchOptions = MonknotSearchOptions()
    ) {
        enqueueReplacement(.all, in: documentID, options: options)
    }

    mutating func consumeReplacement(serial: Int) {
        guard replacementRequest?.serial == serial else { return }
        replacementRequest = nil
    }

    mutating func findNext() {
        if !isPresented {
            present()
            return
        }

        navigationDirection = .next
        navigationSerial += 1
    }

    mutating func findPrevious() {
        if !isPresented {
            present()
            return
        }

        navigationDirection = .previous
        navigationSerial += 1
    }

    mutating func updateResult(_ result: DocumentSearchResult) {
        let nextTotalCount = max(0, result.totalCount)
        var nextCurrentIndex = max(0, result.currentIndex)
        if nextTotalCount == 0 {
            nextCurrentIndex = 0
        } else if nextCurrentIndex == 0 {
            nextCurrentIndex = 1
        } else if nextCurrentIndex > nextTotalCount {
            nextCurrentIndex = nextTotalCount
        }

        guard currentIndex != nextCurrentIndex || totalCount != nextTotalCount else { return }
        currentIndex = nextCurrentIndex
        totalCount = nextTotalCount
    }

    private mutating func enqueueReplacement(
        _ action: DocumentReplacementAction,
        in documentID: String,
        options: MonknotSearchOptions
    ) {
        let effectiveQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPresented, !effectiveQuery.isEmpty else { return }
        nextReplacementSerial += 1
        replacementRequest = DocumentReplacementRequest(
            serial: nextReplacementSerial,
            documentID: documentID,
            query: effectiveQuery,
            replacement: replacement,
            action: action,
            matchIndex: max(0, currentIndex - 1),
            options: options
        )
    }
}

struct DocumentSearchRequest: Equatable {
    let isPresented: Bool
    let query: String
    let navigationSerial: Int
    let navigationDirection: DocumentSearchDirection
    let options: MonknotSearchOptions

    init(
        _ state: DocumentSearchState,
        options: MonknotSearchOptions = MonknotSearchOptions()
    ) {
        isPresented = state.isPresented
        query = state.effectiveQuery
        navigationSerial = state.navigationSerial
        navigationDirection = state.navigationDirection
        self.options = options
    }
}
