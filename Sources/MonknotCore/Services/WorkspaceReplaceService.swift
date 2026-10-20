import Foundation

public struct WorkspaceReplaceFileResult: Equatable, Sendable {
    public let documentID: String
    public let relativePath: String
    public let displayName: String
    public let replacementCount: Int

    public init(
        documentID: String,
        relativePath: String,
        displayName: String,
        replacementCount: Int
    ) {
        self.documentID = documentID
        self.relativePath = relativePath
        self.displayName = displayName
        self.replacementCount = replacementCount
    }
}

public struct WorkspaceReplaceBatch: Sendable {
    public let fileResults: [WorkspaceReplaceFileResult]
    public let totalReplacements: Int
    public let skippedDirtyCount: Int
    public let skippedLargeFileCount: Int
    /// Files left as they are because they changed on disk after they were read, or could not be
    /// written; nothing of theirs is overwritten.
    public let skippedChangedCount: Int
    public let updatedTextsByDocumentID: [String: String]
    public let previousTextsByDocumentID: [String: String]

    public init(
        fileResults: [WorkspaceReplaceFileResult],
        totalReplacements: Int,
        skippedDirtyCount: Int = 0,
        skippedLargeFileCount: Int = 0,
        skippedChangedCount: Int = 0,
        updatedTextsByDocumentID: [String: String] = [:],
        previousTextsByDocumentID: [String: String] = [:]
    ) {
        self.fileResults = fileResults
        self.totalReplacements = totalReplacements
        self.skippedDirtyCount = skippedDirtyCount
        self.skippedLargeFileCount = skippedLargeFileCount
        self.skippedChangedCount = skippedChangedCount
        self.updatedTextsByDocumentID = updatedTextsByDocumentID
        self.previousTextsByDocumentID = previousTextsByDocumentID
    }
}

public struct WorkspaceReplaceService: Sendable {
    public let maxTextFileBytes: Int64
    public let textCache: WorkspaceTextContentCache

    public init(
        maxTextFileBytes: Int64 = WorkspaceTextFileGuard.defaultMaxBytes,
        textCache: WorkspaceTextContentCache = .shared
    ) {
        self.maxTextFileBytes = maxTextFileBytes
        self.textCache = textCache
    }

    public func replaceAndWrite(
        find: String,
        replacement: String,
        options: MonknotSearchOptions = MonknotSearchOptions(),
        documents: [WorkspaceDocument],
        skipDocumentIDs: Set<String> = [],
        limitToDocumentIDs: Set<String>? = nil
    ) throws -> WorkspaceReplaceBatch {
        let plan = try planReplacements(
            find: find,
            replacement: replacement,
            options: options,
            documents: documents,
            skipDocumentIDs: skipDocumentIDs,
            limitToDocumentIDs: limitToDocumentIDs
        )

        // Each file is written only while it still holds the text the plan read, so an edit made
        // in the meantime is never overwritten; the batch (and its undo) holds the files written.
        var written = Set<String>()
        for document in documents {
            try Task.checkCancellation()
            guard let updatedText = plan.updatedTexts[document.id],
                  let previousText = plan.previousTexts[document.id],
                  Self.write(updatedText, to: document.url, expecting: previousText)
            else { continue }
            textCache.store(text: updatedText, for: document.url)
            written.insert(document.id)
        }

        let fileResults = plan.fileResults.filter { written.contains($0.documentID) }
        return WorkspaceReplaceBatch(
            fileResults: fileResults,
            totalReplacements: fileResults.reduce(0) { $0 + $1.replacementCount },
            skippedDirtyCount: plan.skippedDirtyCount,
            skippedLargeFileCount: plan.skippedLargeFileCount,
            skippedChangedCount: plan.fileResults.count - fileResults.count,
            updatedTextsByDocumentID: plan.updatedTexts.filter { written.contains($0.key) },
            previousTextsByDocumentID: plan.previousTexts.filter { written.contains($0.key) }
        )
    }

    /// Writes `text` only while the file holds `expectedText`; false leaves the file as it is.
    private static func write(_ text: String, to url: URL, expecting expectedText: String) -> Bool {
        let expected = WorkspaceTextRevision(
            text: expectedText,
            signature: WorkspaceFileSignature(modificationDate: nil, fileSize: nil)
        )
        return (try? WorkspaceConditionalTextWriter.write(text, to: url, expecting: .present(expected))) != nil
    }

    public func preview(
        find: String,
        replacement: String,
        options: MonknotSearchOptions = MonknotSearchOptions(),
        documents: [WorkspaceDocument],
        skipDocumentIDs: Set<String> = [],
        limitToDocumentIDs: Set<String>? = nil
    ) throws -> WorkspaceReplacePreview {
        let plan = try planReplacements(
            find: find,
            replacement: replacement,
            options: options,
            documents: documents,
            skipDocumentIDs: skipDocumentIDs,
            limitToDocumentIDs: limitToDocumentIDs
        )

        return WorkspaceReplacePreview(
            fileResults: plan.fileResults,
            totalReplacements: plan.totalReplacements,
            skippedDirtyCount: plan.skippedDirtyCount,
            skippedLargeFileCount: plan.skippedLargeFileCount
        )
    }

    private struct ReplacementPlan {
        var fileResults: [WorkspaceReplaceFileResult]
        var totalReplacements: Int
        var skippedDirtyCount: Int
        var skippedLargeFileCount: Int
        var updatedTexts: [String: String]
        var previousTexts: [String: String]
    }

    private func planReplacements(
        find: String,
        replacement: String,
        options: MonknotSearchOptions,
        documents: [WorkspaceDocument],
        skipDocumentIDs: Set<String>,
        limitToDocumentIDs: Set<String>?
    ) throws -> ReplacementPlan {
        let needle = find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return ReplacementPlan(
                fileResults: [],
                totalReplacements: 0,
                skippedDirtyCount: 0,
                skippedLargeFileCount: 0,
                updatedTexts: [:],
                previousTexts: [:]
            )
        }

        var fileResults: [WorkspaceReplaceFileResult] = []
        var updatedTexts: [String: String] = [:]
        var previousTexts: [String: String] = [:]
        var totalReplacements = 0
        var skippedDirtyCount = 0
        var skippedLargeFileCount = 0

        for document in documents {
            try Task.checkCancellation()

            guard document.capabilities.canEditText else { continue }
            guard document.kind == .markdown || document.kind == .text else { continue }

            if let limitToDocumentIDs, !limitToDocumentIDs.contains(document.id) {
                continue
            }

            if skipDocumentIDs.contains(document.id) {
                skippedDirtyCount += 1
                continue
            }

            let text: String
            do {
                text = try WorkspaceTextFileGuard.readUTF8Text(
                    from: document.url,
                    maxBytes: maxTextFileBytes,
                    cache: textCache
                )
            } catch WorkspaceTextFileGuard.Error.fileTooLarge {
                skippedLargeFileCount += 1
                continue
            } catch is WorkspaceTextFileGuard.Error {
                continue
            }

            let replaced = Self.replacedText(
                find: needle,
                replacement: replacement,
                options: options,
                in: text
            )
            guard replaced.count > 0 else { continue }

            previousTexts[document.id] = text
            fileResults.append(WorkspaceReplaceFileResult(
                documentID: document.id,
                relativePath: document.relativePath,
                displayName: document.displayName,
                replacementCount: replaced.count
            ))
            updatedTexts[document.id] = replaced.text
            totalReplacements += replaced.count
        }

        return ReplacementPlan(
            fileResults: fileResults,
            totalReplacements: totalReplacements,
            skippedDirtyCount: skippedDirtyCount,
            skippedLargeFileCount: skippedLargeFileCount,
            updatedTexts: updatedTexts,
            previousTexts: previousTexts
        )
    }

    /// Puts back the text each file held before a replace, only in files that still hold the text
    /// the replace wrote: a file changed since (in another app, by git, by a sync client) keeps
    /// its newer text and is counted in `skippedChangedCount`.
    public func restoreAndWrite(
        _ snapshot: WorkspaceReplaceUndoSnapshot,
        documents: [WorkspaceDocument]
    ) throws -> WorkspaceReplaceBatch {
        var fileResults: [WorkspaceReplaceFileResult] = []
        var updatedTexts: [String: String] = [:]
        var skippedChangedCount = 0

        for document in documents {
            try Task.checkCancellation()
            guard let previousText = snapshot.previousTextsByDocumentID[document.id],
                  let replacedText = snapshot.replacedTextsByDocumentID[document.id]
            else { continue }
            guard Self.write(previousText, to: document.url, expecting: replacedText) else {
                skippedChangedCount += 1
                continue
            }
            textCache.store(text: previousText, for: document.url)

            fileResults.append(WorkspaceReplaceFileResult(
                documentID: document.id,
                relativePath: document.relativePath,
                displayName: document.displayName,
                replacementCount: 0
            ))
            updatedTexts[document.id] = previousText
        }

        return WorkspaceReplaceBatch(
            fileResults: fileResults,
            totalReplacements: 0,
            skippedChangedCount: skippedChangedCount,
            updatedTextsByDocumentID: updatedTexts
        )
    }

    static func replacedText(
        find: String,
        replacement: String,
        options: MonknotSearchOptions = MonknotSearchOptions(),
        in text: String
    ) -> (text: String, count: Int) {
        let matches = MonknotTextSearch.matchingRanges(of: find, in: text, options: options)
        guard !matches.isEmpty else { return (text, 0) }

        let result = NSMutableString(string: text)
        for range in matches.reversed() {
            result.replaceCharacters(in: range, with: replacement)
        }
        return (result as String, matches.count)
    }
}
