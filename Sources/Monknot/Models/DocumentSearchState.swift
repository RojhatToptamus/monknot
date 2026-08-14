import Foundation
import MonknotCore

enum DocumentSearchDirection: String, Equatable {
    case next
    case previous
}

struct DocumentSearchResult: Equatable {
    var currentIndex: Int = 0
    var totalCount: Int = 0
}

struct DocumentSearchState: Equatable {
    var isPresented = false
    var query = ""
    var currentIndex = 0
    var totalCount = 0
    var navigationSerial = 0
    var navigationDirection: DocumentSearchDirection = .next
    var focusSerial = 0

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
        updateResult(.init())
    }

    mutating func setQuery(_ nextQuery: String) {
        guard query != nextQuery else { return }
        query = nextQuery
        updateResult(.init())
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
