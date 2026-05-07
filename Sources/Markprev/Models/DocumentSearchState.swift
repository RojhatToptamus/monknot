import Foundation

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
        currentIndex = max(0, result.currentIndex)
        totalCount = max(0, result.totalCount)
        if totalCount == 0 {
            currentIndex = 0
        } else if currentIndex == 0 {
            currentIndex = 1
        } else if currentIndex > totalCount {
            currentIndex = totalCount
        }
    }
}

struct DocumentSearchRequest: Equatable {
    let isPresented: Bool
    let query: String
    let navigationSerial: Int
    let navigationDirection: DocumentSearchDirection

    init(_ state: DocumentSearchState) {
        isPresented = state.isPresented
        query = state.effectiveQuery
        navigationSerial = state.navigationSerial
        navigationDirection = state.navigationDirection
    }
}
