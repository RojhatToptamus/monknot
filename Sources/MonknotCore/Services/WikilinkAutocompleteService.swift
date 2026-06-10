import Foundation

public struct WikilinkCompletionContext: Equatable, Sendable {
    public var partialText: String
    public var replaceRangeLocation: Int
    public var replaceRangeLength: Int

    public init(partialText: String, replaceRangeLocation: Int, replaceRangeLength: Int) {
        self.partialText = partialText
        self.replaceRangeLocation = replaceRangeLocation
        self.replaceRangeLength = replaceRangeLength
    }
}

public enum WikilinkAutocompleteService {
    public static func activeCompletion(in text: String, cursorUTF16Offset: Int) -> WikilinkCompletionContext? {
        let nsText = text as NSString
        guard cursorUTF16Offset >= 0, cursorUTF16Offset <= nsText.length else { return nil }

        let prefix = nsText.substring(to: cursorUTF16Offset)
        guard let openRange = prefix.range(of: "[[", options: .backwards) else { return nil }

        let partialStart = prefix.index(openRange.upperBound, offsetBy: 0)
        let partial = String(prefix[partialStart...])
        guard !partial.contains("]]") else { return nil }

        let replaceStart = (prefix[..<partialStart] as NSString).length
        let replaceLength = cursorUTF16Offset - replaceStart

        return WikilinkCompletionContext(
            partialText: partial,
            replaceRangeLocation: replaceStart,
            replaceRangeLength: max(0, replaceLength)
        )
    }

    private static func wikilinkTitle(for document: WorkspaceDocument) -> String {
        if document.kind == .markdown, document.displayName.lowercased().hasSuffix(".md") {
            return String(document.displayName.dropLast(3))
        }
        return document.displayName
    }

    public static func suggestions(
        partial: String,
        documents: [WorkspaceDocument],
        limit: Int = 12
    ) -> [String] {
        let markdownDocuments = documents.filter { $0.kind == .markdown }
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPartial = trimmed.lowercased()

        let candidates = markdownDocuments.map { document -> (title: String, score: Int) in
            let title = Self.wikilinkTitle(for: document)
            let normalizedTitle = title.lowercased()
            let pathTitle = document.relativePath
                .replacingOccurrences(of: ".md", with: "", options: [.caseInsensitive, .anchored])
                .split(separator: "/")
                .last
                .map(String.init) ?? title

            var score = 0
            if normalizedPartial.isEmpty {
                score = 1
            } else if normalizedTitle.hasPrefix(normalizedPartial) {
                score = 100 - normalizedTitle.count
            } else if normalizedTitle.contains(normalizedPartial) {
                score = 50 - normalizedTitle.count
            } else if pathTitle.lowercased().contains(normalizedPartial) {
                score = 30 - pathTitle.count
            }

            return (title, score)
        }
        .filter { $0.score > 0 }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        var seen = Set<String>()
        var results: [String] = []
        results.reserveCapacity(limit)

        for candidate in candidates {
            guard seen.insert(candidate.title).inserted else { continue }
            results.append(candidate.title)
            if results.count == limit { break }
        }

        return results
    }

    public static func bestSuggestion(
        partial: String,
        documents: [WorkspaceDocument]
    ) -> String? {
        suggestions(partial: partial, documents: documents, limit: 1).first
    }
}
