import Foundation

public struct RelatedNoteMatch: Identifiable, Hashable, Sendable {
    public let id: String
    public let relativePath: String
    public let displayName: String
    public let score: Int
    public let reason: String

    public init(relativePath: String, displayName: String, score: Int, reason: String) {
        self.id = relativePath
        self.relativePath = relativePath
        self.displayName = displayName
        self.score = score
        self.reason = reason
    }
}

public struct RelatedNotesService: Sendable {
    public let maxResults: Int
    public let maxFileBytes: Int64
    public let maxCandidateDocuments: Int

    public init(
        maxResults: Int = 5,
        maxFileBytes: Int64 = 1 * 1024 * 1024,
        maxCandidateDocuments: Int = 40
    ) {
        self.maxResults = maxResults
        self.maxFileBytes = maxFileBytes
        self.maxCandidateDocuments = max(0, maxCandidateDocuments)
    }

    public func relatedNotes(
        for document: WorkspaceDocument,
        documents: [WorkspaceDocument],
        textCache: WorkspaceTextContentCache = .shared
    ) -> [RelatedNoteMatch] {
        guard document.kind == .markdown, document.capabilities.canSearchText else { return [] }
        guard !Task.isCancelled else { return [] }

        let currentText: String
        do {
            currentText = try WorkspaceTextFileGuard.readUTF8Text(
                from: document.url,
                maxBytes: maxFileBytes,
                cache: textCache
            )
        } catch {
            return []
        }

        let headings = Self.extractHeadings(from: currentText)
        let tags = Self.extractTags(from: currentText)
        guard !headings.isEmpty || !tags.isEmpty else { return [] }
        guard maxCandidateDocuments > 0 else { return [] }

        var scores: [String: (score: Int, reasons: Set<String>)] = [:]
        let candidates = candidateDocuments(for: document, in: documents)

        for candidate in candidates {
            guard !Task.isCancelled else { return [] }

            let candidateText: String
            do {
                candidateText = try WorkspaceTextFileGuard.readUTF8Text(
                    from: candidate.url,
                    maxBytes: maxFileBytes,
                    cache: textCache
                )
            } catch {
                continue
            }

            let candidateHeadings = Set(Self.extractHeadings(from: candidateText).map { $0.lowercased() })
            let candidateTags = Set(Self.extractTags(from: candidateText).map { $0.lowercased() })

            var score = 0
            var reasons = Set<String>()

            for heading in headings {
                let normalized = heading.lowercased()
                if candidateHeadings.contains(normalized) {
                    score += 3
                    reasons.insert("shared heading")
                } else if candidateText.localizedCaseInsensitiveContains(heading) {
                    score += 1
                    reasons.insert("similar title")
                }
            }

            for tag in tags {
                let normalized = tag.lowercased()
                if candidateTags.contains(normalized) {
                    score += 4
                    reasons.insert("shared tag")
                } else if candidateText.localizedCaseInsensitiveContains("#\(normalized)") {
                    score += 2
                    reasons.insert("tag mention")
                }
            }

            if score > 0 {
                let existing = scores[candidate.relativePath]?.score ?? 0
                var mergedReasons = scores[candidate.relativePath]?.reasons ?? []
                mergedReasons.formUnion(reasons)
                scores[candidate.relativePath] = (existing + score, mergedReasons)
            }
        }

        guard !Task.isCancelled else { return [] }

        return scores
            .map { relativePath, value in
                RelatedNoteMatch(
                    relativePath: relativePath,
                    displayName: WorkspaceDocumentSupport.displayName(forRelativePath: relativePath),
                    score: value.score,
                    reason: value.reasons.sorted().joined(separator: ", ")
                )
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
                }
                return lhs.score > rhs.score
            }
            .prefix(maxResults)
            .map { $0 }
    }

    private func candidateDocuments(
        for document: WorkspaceDocument,
        in documents: [WorkspaceDocument]
    ) -> ArraySlice<WorkspaceDocument> {
        let selectedDirectory = Self.directoryPath(for: document.relativePath)

        return documents
            .filter { candidate in
                candidate.id != document.id &&
                    candidate.kind == .markdown &&
                    candidate.capabilities.canSearchText
            }
            .sorted { lhs, rhs in
                let lhsSameDirectory = Self.directoryPath(for: lhs.relativePath) == selectedDirectory
                let rhsSameDirectory = Self.directoryPath(for: rhs.relativePath) == selectedDirectory

                if lhsSameDirectory != rhsSameDirectory {
                    return lhsSameDirectory
                }

                return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
            .prefix(maxCandidateDocuments)
    }

    private static func directoryPath(for relativePath: String) -> String {
        let components = relativePath.split(separator: "/").dropLast()
        return components.joined(separator: "/")
    }

    public static func extractHeadings(from text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("#") else { return nil }
                let title = trimmed.drop(while: { $0 == "#" || $0 == " " })
                let value = String(title).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
    }

    public static func extractTags(from text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = tagRegex.matches(in: text, range: range)

        var tags: [String] = []
        var seen = Set<String>()
        for match in matches {
            guard match.numberOfRanges == 2,
                  let tagRange = Range(match.range(at: 1), in: text) else { continue }
            let tag = String(text[tagRange])
            guard seen.insert(tag.lowercased()).inserted else { continue }
            tags.append(tag)
        }
        return tags
    }

    private static let tagRegex = try! NSRegularExpression(pattern: #"(?<!\w)#([a-zA-Z0-9_-]+)"#)
}
