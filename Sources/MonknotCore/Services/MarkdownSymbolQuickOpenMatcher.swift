import Foundation

public enum MarkdownSymbolQuickOpenMatcher {
    public static func rankedItems(
        query: String,
        items: [MarkdownOutlineItem],
        limit: Int = 50
    ) -> [MarkdownOutlineItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(items.prefix(limit))
        }

        let normalizedQuery = trimmed.lowercased()
        var scored: [(item: MarkdownOutlineItem, score: Int)] = []
        scored.reserveCapacity(items.count)

        for item in items {
            let score = matchScore(query: normalizedQuery, in: item.title.lowercased())
            guard score > 0 else { continue }
            scored.append((item, score))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.item.level != rhs.item.level { return lhs.item.level < rhs.item.level }
                return lhs.item.location.line < rhs.item.location.line
            }
            .prefix(limit)
            .map(\.item)
    }

    private static func matchScore(query: String, in haystack: String) -> Int {
        guard !query.isEmpty, !haystack.isEmpty else { return 0 }

        var score = 0
        var queryIndex = query.startIndex
        var previousMatchIndex: String.Index?
        var consecutiveBonus = 0

        for (index, character) in haystack.enumerated() {
            guard queryIndex < query.endIndex else { break }
            guard character == query[queryIndex] else { continue }

            let stringIndex = haystack.index(haystack.startIndex, offsetBy: index)
            score += 10

            if index == 0 || haystack[haystack.index(before: stringIndex)].isWhitespace {
                score += 20
            }

            if let previousMatchIndex,
               haystack.distance(from: previousMatchIndex, to: stringIndex) == 1 {
                consecutiveBonus += 5
            } else {
                consecutiveBonus = 0
            }
            score += consecutiveBonus

            previousMatchIndex = stringIndex
            queryIndex = query.index(after: queryIndex)
        }

        guard queryIndex == query.endIndex else { return 0 }

        if haystack.hasPrefix(query) {
            score += 35
        }

        return score
    }
}
