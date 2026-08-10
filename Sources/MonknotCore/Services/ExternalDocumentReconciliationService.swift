import Foundation

public struct ExternalDocumentReconciliationReview: Equatable, Sendable {
    public let baselineText: String
    public let localText: String
    public let diskRevision: WorkspaceTextRevision?
    public let mergedText: String?

    public init(
        baselineText: String,
        localText: String,
        diskRevision: WorkspaceTextRevision?,
        mergedText: String?
    ) {
        self.baselineText = baselineText
        self.localText = localText
        self.diskRevision = diskRevision
        self.mergedText = mergedText
    }

    public var diskText: String? { diskRevision?.text }
}

public enum ExternalDocumentReconciliationService {
    public static func review(
        baselineText: String,
        localText: String,
        diskRevision: WorkspaceTextRevision?
    ) -> ExternalDocumentReconciliationReview {
        let mergedText = diskRevision.flatMap {
            merge(baseline: baselineText, local: localText, disk: $0.text)
        }
        return ExternalDocumentReconciliationReview(
            baselineText: baselineText,
            localText: localText,
            diskRevision: diskRevision,
            mergedText: mergedText
        )
    }

    /// Returns a result only when the two edits are identical, one side is
    /// unchanged, or each side has one demonstrably disjoint replacement.
    /// Ambiguous overlap is deliberately left for the user to reconcile.
    public static func merge(baseline: String, local: String, disk: String) -> String? {
        if local == disk { return local }
        if local == baseline { return disk }
        if disk == baseline { return local }

        let localEdit = minimalEdit(from: baseline, to: local)
        let diskEdit = minimalEdit(from: baseline, to: disk)

        guard editsAreDisjoint(localEdit, diskEdit) else { return nil }

        var result = Array(baseline)
        for edit in [localEdit, diskEdit].sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        return String(result)
    }

    private struct TextEdit {
        let range: Range<Int>
        let replacement: [Character]
    }

    private static func minimalEdit(from baseline: String, to changed: String) -> TextEdit {
        let original = Array(baseline)
        let replacement = Array(changed)
        let prefixCount = zip(original, replacement).prefix { pair in
            pair.0 == pair.1
        }.count

        let remainingOriginal = original.count - prefixCount
        let remainingReplacement = replacement.count - prefixCount
        let suffixCount = zip(
            original.suffix(remainingOriginal).reversed(),
            replacement.suffix(remainingReplacement).reversed()
        ).prefix { pair in
            pair.0 == pair.1
        }.count

        let range = prefixCount..<(original.count - suffixCount)
        let replacementRange = prefixCount..<(replacement.count - suffixCount)
        return TextEdit(
            range: range,
            replacement: Array(replacement[replacementRange])
        )
    }

    private static func editsAreDisjoint(_ first: TextEdit, _ second: TextEdit) -> Bool {
        if first.range.isEmpty, second.range.isEmpty,
           first.range.lowerBound == second.range.lowerBound {
            return false
        }
        return first.range.upperBound <= second.range.lowerBound
            || second.range.upperBound <= first.range.lowerBound
    }
}
