import Foundation

public enum WorkspaceQuickOpenMatcher {
    public static func rankedDocuments(
        query: String,
        documents: [WorkspaceDocument],
        limit: Int = 50
    ) -> [WorkspaceDocument] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(documents.prefix(limit))
        }

        let normalizedQuery = trimmed.lowercased()
        var scored: [(document: WorkspaceDocument, score: Int)] = []
        scored.reserveCapacity(documents.count)

        for document in documents {
            let score = matchScore(query: normalizedQuery, in: document.relativePath.lowercased())
                + matchScore(query: normalizedQuery, in: document.displayName.lowercased()) / 2
            guard score > 0 else { continue }
            scored.append((document, score))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.document.relativePath.localizedCaseInsensitiveCompare(rhs.document.relativePath) == .orderedAscending
            }
            .prefix(limit)
            .map(\.document)
    }

    private static func matchScore(query: String, in haystack: String) -> Int {
        guard !query.isEmpty, !haystack.isEmpty else { return 0 }

        var score = 0
        var queryIndex = query.startIndex
        var previousMatchIndex: String.Index?
        var consecutiveBonus = 0

        for (index, character) in haystack.enumerated() {
            guard queryIndex < query.endIndex else { break }

            let haystackCharacter = character
            let queryCharacter = query[queryIndex]
            guard haystackCharacter == queryCharacter else { continue }

            let stringIndex = haystack.index(haystack.startIndex, offsetBy: index)
            score += 10

            if index == 0 || haystack[haystack.index(before: stringIndex)].isPathSeparator {
                score += 25
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
            score += 40
        }

        return score
    }
}

private extension Character {
    var isPathSeparator: Bool {
        self == "/" || self == "\\"
    }
}
