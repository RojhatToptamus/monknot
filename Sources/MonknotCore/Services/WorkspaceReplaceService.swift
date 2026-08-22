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
    public let updatedTextsByDocumentID: [String: String]
    public let previousTextsByDocumentID: [String: String]

    public init(
        fileResults: [WorkspaceReplaceFileResult],
        totalReplacements: Int,
        skippedDirtyCount: Int = 0,
        skippedLargeFileCount: Int = 0,
        updatedTextsByDocumentID: [String: String] = [:],
        previousTextsByDocumentID: [String: String] = [:]
    ) {
        self.fileResults = fileResults
        self.totalReplacements = totalReplacements
        self.skippedDirtyCount = skippedDirtyCount
        self.skippedLargeFileCount = skippedLargeFileCount
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

        for document in documents {
            guard let updatedText = plan.updatedTexts[document.id] else { continue }
            try updatedText.write(to: document.url, atomically: true, encoding: .utf8)
            textCache.store(text: updatedText, for: document.url)
        }

        return WorkspaceReplaceBatch(
            fileResults: plan.fileResults,
            totalReplacements: plan.totalReplacements,
            skippedDirtyCount: plan.skippedDirtyCount,
            skippedLargeFileCount: plan.skippedLargeFileCount,
            updatedTextsByDocumentID: plan.updatedTexts,
            previousTextsByDocumentID: plan.previousTexts
        )
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

    public func restoreAndWrite(
        previousTextsByDocumentID: [String: String],
        documents: [WorkspaceDocument]
    ) throws -> WorkspaceReplaceBatch {
        var fileResults: [WorkspaceReplaceFileResult] = []
        var updatedTexts: [String: String] = [:]

        for document in documents {
            try Task.checkCancellation()
            guard let previousText = previousTextsByDocumentID[document.id] else { continue }

            try previousText.write(to: document.url, atomically: true, encoding: .utf8)
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
