import Foundation
import PDFKit

public struct WorkspaceSearchService: Sendable {
    public let maxMatches: Int
    public let maxMatchesPerFile: Int

    public init(maxMatches: Int = 500, maxMatchesPerFile: Int = 50) {
        self.maxMatches = maxMatches
        self.maxMatchesPerFile = maxMatchesPerFile
    }

    public func search(query: String, documents: [WorkspaceDocument]) throws -> [WorkspaceSearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var results: [WorkspaceSearchResult] = []
        for document in documents {
            try Task.checkCancellation()

            let matches: [WorkspaceSearchResult]
            switch document.kind {
            case .markdown, .text:
                let text = try String(contentsOf: document.url, encoding: .utf8)
                matches = Self.matches(
                    needle: needle,
                    text: text,
                    document: document,
                    resultKind: .text,
                    limit: maxMatchesPerFile
                )
            case .pdf:
                matches = try Self.pdfMatches(
                    needle: needle,
                    document: document,
                    limit: maxMatchesPerFile
                )
            case .media, .nativePreview, .unsupported:
                continue
            }

            results.append(contentsOf: matches)
            if results.count >= maxMatches {
                return Array(results.prefix(maxMatches))
            }
        }

        return results
    }

    private static func matches(
        needle: String,
        text: String,
        document: WorkspaceDocument,
        resultKind: WorkspaceSearchResultKind,
        limit: Int
    ) -> [WorkspaceSearchResult] {
        guard limit > 0 else { return [] }

        var results: [WorkspaceSearchResult] = []
        let nsNeedle = needle as NSString
        var lineNumber = 1

        text.enumerateLines { line, stop in
            let nsLine = line as NSString
            var searchRange = NSRange(location: 0, length: nsLine.length)

            while searchRange.length > 0 {
                let found = nsLine.range(
                    of: nsNeedle as String,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )

                guard found.location != NSNotFound, found.length > 0 else { break }

                let preview = line.trimmingCharacters(in: .whitespacesAndNewlines)
                results.append(WorkspaceSearchResult(
                    id: "\(document.id):\(lineNumber):\(found.location)",
                    documentID: document.id,
                    relativePath: document.relativePath,
                    displayName: document.displayName,
                    kind: resultKind,
                    line: lineNumber,
                    column: found.location,
                    preview: preview.isEmpty ? line : preview
                ))

                if results.count >= limit {
                    stop = true
                    return
                }

                let nextLocation = found.location + found.length
                guard nextLocation < nsLine.length else { break }
                searchRange = NSRange(location: nextLocation, length: nsLine.length - nextLocation)
            }

            lineNumber += 1
        }

        return results
    }

    private static func pdfMatches(needle: String, document: WorkspaceDocument, limit: Int) throws -> [WorkspaceSearchResult] {
        guard let pdf = PDFDocument(url: document.url) else { return [] }

        var results: [WorkspaceSearchResult] = []
        for pageIndex in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: pageIndex), let text = page.string else { continue }
            let matches = matches(
                needle: needle,
                text: text,
                document: document,
                resultKind: .pdf,
                limit: max(0, limit - results.count)
            ).enumerated().map { offset, match in
                let matchIndex = results.count + offset
                return WorkspaceSearchResult(
                    id: "\(document.id):pdf:\(pageIndex + 1):\(match.column):\(matchIndex)",
                    documentID: match.documentID,
                    relativePath: match.relativePath,
                    displayName: match.displayName,
                    kind: .pdf,
                    line: pageIndex + 1,
                    column: match.column,
                    preview: match.preview,
                    pdfTarget: WorkspaceSearchPDFTarget(page: pageIndex + 1, matchIndex: matchIndex)
                )
            }
            results.append(contentsOf: matches)
            if results.count >= limit {
                return Array(results.prefix(limit))
            }
        }

        return results
    }
}
