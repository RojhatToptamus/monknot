import Foundation

public struct WorkspaceContextAssembler: Sendable {
    public let searchService: WorkspaceSearchService
    public let contextLineRadius: Int
    public let maxChunks: Int
    public let maxCharacters: Int

    public init(
        searchService: WorkspaceSearchService = WorkspaceSearchService(maxMatches: 80, maxMatchesPerFile: 20),
        contextLineRadius: Int = 3,
        maxChunks: Int = 12,
        maxCharacters: Int = 12_000
    ) {
        self.searchService = searchService
        self.contextLineRadius = contextLineRadius
        self.maxChunks = maxChunks
        self.maxCharacters = maxCharacters
    }

    public func assemble(
        question: String,
        documents: [WorkspaceDocument],
        preferredRelativePaths: [String] = []
    ) throws -> [WorkspaceContextChunk] {
        let terms = Self.searchTerms(from: question)
        guard !terms.isEmpty else { return [] }

        let preferredDocuments = Self.preferredDocuments(
            from: documents,
            preferredRelativePaths: preferredRelativePaths
        )
        let preferredPathSet = Set(preferredDocuments.map(\.relativePath))
        let remainingDocuments = documents.filter { !preferredPathSet.contains($0.relativePath) }

        var chunks: [WorkspaceContextChunk] = []
        var seenChunkIDs = Set<String>()
        var totalCharacters = 0

        try appendChunks(
            from: preferredDocuments,
            terms: terms,
            preferredFallback: true,
            chunks: &chunks,
            seenChunkIDs: &seenChunkIDs,
            totalCharacters: &totalCharacters
        )

        if chunks.count < maxChunks, totalCharacters < maxCharacters {
            try appendChunks(
                from: remainingDocuments,
                terms: terms,
                preferredFallback: false,
                chunks: &chunks,
                seenChunkIDs: &seenChunkIDs,
                totalCharacters: &totalCharacters
            )
        }

        return chunks
    }

    static func preferredDocuments(
        from documents: [WorkspaceDocument],
        preferredRelativePaths: [String]
    ) -> [WorkspaceDocument] {
        guard !preferredRelativePaths.isEmpty else { return [] }

        var ordered: [WorkspaceDocument] = []
        var seen = Set<String>()
        for path in preferredRelativePaths {
            guard let document = documents.first(where: { $0.relativePath == path }),
                  seen.insert(document.id).inserted else { continue }
            ordered.append(document)
        }
        return ordered
    }

    private func appendChunks(
        from documents: [WorkspaceDocument],
        terms: [String],
        preferredFallback: Bool,
        chunks: inout [WorkspaceContextChunk],
        seenChunkIDs: inout Set<String>,
        totalCharacters: inout Int
    ) throws {
        guard !documents.isEmpty else { return }

        var documentsWithFallback = Set<String>()

        for term in terms {
            try Task.checkCancellation()
            let batch = try searchService.search(query: term, documents: documents)
            for result in batch.results where result.kind == .text {
                guard let document = documents.first(where: { $0.id == result.documentID }) else { continue }
                let text: String
                do {
                    text = try WorkspaceTextFileGuard.readUTF8Text(
                        from: document.url,
                        cache: searchService.textCache
                    )
                } catch {
                    continue
                }

                guard let chunk = chunk(
                    around: result.line,
                    in: text,
                    relativePath: document.relativePath
                ) else { continue }

                guard appendChunk(
                    chunk,
                    chunks: &chunks,
                    seenChunkIDs: &seenChunkIDs,
                    totalCharacters: &totalCharacters
                ) else { return }
            }

            if chunks.count >= maxChunks || totalCharacters >= maxCharacters {
                return
            }
        }

        guard preferredFallback else { return }

        for document in documents {
            try Task.checkCancellation()
            guard !documentsWithFallback.contains(document.relativePath) else { continue }

            let text: String
            do {
                text = try WorkspaceTextFileGuard.readUTF8Text(
                    from: document.url,
                    cache: searchService.textCache
                )
            } catch {
                continue
            }

            guard let chunk = chunk(around: 1, in: text, relativePath: document.relativePath) else { continue }
            documentsWithFallback.insert(document.relativePath)
            guard appendChunk(
                chunk,
                chunks: &chunks,
                seenChunkIDs: &seenChunkIDs,
                totalCharacters: &totalCharacters
            ) else { return }
        }
    }

    private func appendChunk(
        _ chunk: WorkspaceContextChunk,
        chunks: inout [WorkspaceContextChunk],
        seenChunkIDs: inout Set<String>,
        totalCharacters: inout Int
    ) -> Bool {
        guard seenChunkIDs.insert(chunk.id).inserted else { return true }
        guard totalCharacters + chunk.text.count <= maxCharacters else { return false }

        chunks.append(chunk)
        totalCharacters += chunk.text.count
        return chunks.count < maxChunks
    }

    public static func searchTerms(from question: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "the", "and", "or", "but", "if", "in", "on", "at", "to", "for",
            "of", "with", "by", "from", "is", "are", "was", "were", "be", "been", "being",
            "what", "which", "who", "whom", "where", "when", "why", "how", "do", "does", "did",
            "this", "that", "these", "those", "my", "your", "our", "their", "me", "you", "we", "they",
            "about", "into", "through", "during", "before", "after", "above", "below", "between",
            "can", "could", "should", "would", "will", "just", "not", "no", "yes"
        ]

        let tokens = question
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }

        var unique: [String] = []
        var seen = Set<String>()
        for token in tokens where seen.insert(token).inserted {
            unique.append(token)
        }

        if unique.isEmpty {
            let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 2 {
                return [trimmed]
            }
        }

        return Array(unique.prefix(6))
    }

    private func chunk(around line: Int, in text: String, relativePath: String) -> WorkspaceContextChunk? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }

        let index = max(0, min(line - 1, lines.count - 1))
        let start = max(0, index - contextLineRadius)
        let end = min(lines.count - 1, index + contextLineRadius)
        let slice = lines[start...end]
        let body = slice.enumerated().map { offset, value in
            let lineNumber = start + offset + 1
            return "\(lineNumber): \(value)"
        }.joined(separator: "\n")

        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return WorkspaceContextChunk(
            relativePath: relativePath,
            startLine: start + 1,
            endLine: end + 1,
            text: body
        )
    }
}
