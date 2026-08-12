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

public struct ExternalDocumentUnifiedDiff: Equatable, Sendable {
    public let hunks: [ExternalDocumentDiffHunk]

    public var hasChanges: Bool { !hunks.isEmpty }
}

public struct ExternalDocumentDiffHunk: Equatable, Sendable {
    public let oldStartLine: Int
    public let oldLineCount: Int
    public let newStartLine: Int
    public let newLineCount: Int
    public let lines: [ExternalDocumentDiffLine]
}

public struct ExternalDocumentDiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case context
        case removal
        case addition
    }

    public let kind: Kind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let text: String
    public let hasTerminatingNewline: Bool

    public var indicator: String {
        switch kind {
        case .context: return " "
        case .removal: return "−"
        case .addition: return "+"
        }
    }
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

    /// Builds a line-oriented unified diff only when a caller explicitly asks
    /// for one. Reconciliation and external-change detection do not perform
    /// this presentation work in the background.
    public static func unifiedDiff(
        from oldText: String,
        to newText: String,
        contextLines requestedContextLines: Int = 3
    ) -> ExternalDocumentUnifiedDiff {
        let oldLines = diffLines(in: oldText)
        let newLines = diffLines(in: newText)
        let difference = newLines.difference(from: oldLines)

        guard !difference.isEmpty else {
            return ExternalDocumentUnifiedDiff(hunks: [])
        }

        let removedOffsets = Set(difference.removals.compactMap { change -> Int? in
            guard case .remove(let offset, _, _) = change else { return nil }
            return offset
        })
        let insertedOffsets = Set(difference.insertions.compactMap { change -> Int? in
            guard case .insert(let offset, _, _) = change else { return nil }
            return offset
        })

        var rows: [ExternalDocumentDiffLine] = []
        rows.reserveCapacity(oldLines.count + difference.insertions.count)

        var oldOffset = 0
        var newOffset = 0
        var oldLineNumber = 1
        var newLineNumber = 1

        while oldOffset < oldLines.count || newOffset < newLines.count {
            if oldOffset < oldLines.count, removedOffsets.contains(oldOffset) {
                let line = oldLines[oldOffset]
                rows.append(ExternalDocumentDiffLine(
                    kind: .removal,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: nil,
                    text: line.text,
                    hasTerminatingNewline: line.hasTerminatingNewline
                ))
                oldOffset += 1
                oldLineNumber += 1
                continue
            }

            if newOffset < newLines.count, insertedOffsets.contains(newOffset) {
                let line = newLines[newOffset]
                rows.append(ExternalDocumentDiffLine(
                    kind: .addition,
                    oldLineNumber: nil,
                    newLineNumber: newLineNumber,
                    text: line.text,
                    hasTerminatingNewline: line.hasTerminatingNewline
                ))
                newOffset += 1
                newLineNumber += 1
                continue
            }

            guard oldOffset < oldLines.count, newOffset < newLines.count else {
                // CollectionDifference should account for every unmatched
                // element. Keep this path lossless if that invariant changes.
                if oldOffset < oldLines.count {
                    let line = oldLines[oldOffset]
                    rows.append(ExternalDocumentDiffLine(
                        kind: .removal,
                        oldLineNumber: oldLineNumber,
                        newLineNumber: nil,
                        text: line.text,
                        hasTerminatingNewline: line.hasTerminatingNewline
                    ))
                    oldOffset += 1
                    oldLineNumber += 1
                } else if newOffset < newLines.count {
                    let line = newLines[newOffset]
                    rows.append(ExternalDocumentDiffLine(
                        kind: .addition,
                        oldLineNumber: nil,
                        newLineNumber: newLineNumber,
                        text: line.text,
                        hasTerminatingNewline: line.hasTerminatingNewline
                    ))
                    newOffset += 1
                    newLineNumber += 1
                }
                continue
            }

            let oldLine = oldLines[oldOffset]
            let newLine = newLines[newOffset]
            guard oldLine == newLine else {
                // Be conservative if the standard-library difference ever
                // produces an alignment this walker cannot pair directly.
                rows.append(ExternalDocumentDiffLine(
                    kind: .removal,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: nil,
                    text: oldLine.text,
                    hasTerminatingNewline: oldLine.hasTerminatingNewline
                ))
                rows.append(ExternalDocumentDiffLine(
                    kind: .addition,
                    oldLineNumber: nil,
                    newLineNumber: newLineNumber,
                    text: newLine.text,
                    hasTerminatingNewline: newLine.hasTerminatingNewline
                ))
                oldOffset += 1
                newOffset += 1
                oldLineNumber += 1
                newLineNumber += 1
                continue
            }

            rows.append(ExternalDocumentDiffLine(
                kind: .context,
                oldLineNumber: oldLineNumber,
                newLineNumber: newLineNumber,
                text: oldLine.text,
                hasTerminatingNewline: oldLine.hasTerminatingNewline
            ))
            oldOffset += 1
            newOffset += 1
            oldLineNumber += 1
            newLineNumber += 1
        }

        let contextLines = min(max(0, requestedContextLines), rows.count)
        let changedIndices = rows.indices.filter { rows[$0].kind != .context }
        let hunkRanges = mergedHunkRanges(
            around: changedIndices,
            rowCount: rows.count,
            contextLines: contextLines
        )

        return ExternalDocumentUnifiedDiff(hunks: hunkRanges.map { range in
            let precedingRows = rows[..<range.lowerBound]
            let hunkLines = Array(rows[range])
            let oldLinesBeforeHunk = precedingRows.lazy.filter { $0.kind != .addition }.count
            let newLinesBeforeHunk = precedingRows.lazy.filter { $0.kind != .removal }.count
            let oldLineCount = hunkLines.lazy.filter { $0.kind != .addition }.count
            let newLineCount = hunkLines.lazy.filter { $0.kind != .removal }.count

            return ExternalDocumentDiffHunk(
                oldStartLine: oldLineCount == 0 ? oldLinesBeforeHunk : oldLinesBeforeHunk + 1,
                oldLineCount: oldLineCount,
                newStartLine: newLineCount == 0 ? newLinesBeforeHunk : newLinesBeforeHunk + 1,
                newLineCount: newLineCount,
                lines: hunkLines
            )
        })
    }

    /// Returns a result only when the two edits are identical, one side is
    /// unchanged, or every changed region is demonstrably compatible.
    /// Ambiguous overlap is deliberately left for the user to reconcile.
    public static func merge(baseline: String, local: String, disk: String) -> String? {
        if local == disk { return local }
        if local == baseline { return disk }
        if disk == baseline { return local }

        let localEdits = edits(from: baseline, to: local)
        let diskEdits = edits(from: baseline, to: disk)
        var combinedEdits = localEdits

        for diskEdit in diskEdits {
            var isDuplicate = false
            for localEdit in localEdits {
                if localEdit == diskEdit {
                    isDuplicate = true
                } else if editsConflict(localEdit, diskEdit) {
                    return nil
                }
            }
            if !isDuplicate {
                combinedEdits.append(diskEdit)
            }
        }

        var result = Array(baseline)
        for edit in combinedEdits.sorted(by: editsApplyBefore) {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        return String(result)
    }

    private struct TextEdit: Equatable {
        let range: Range<Int>
        let replacement: [Character]
    }

    private struct DiffLine: Equatable {
        let text: String
        let hasTerminatingNewline: Bool
    }

    private static func diffLines(in text: String) -> [DiffLine] {
        guard !text.isEmpty else { return [] }

        let parts = text.components(separatedBy: "\n")
        let hasTrailingNewline = text.hasSuffix("\n")
        var lines: [DiffLine] = []
        lines.reserveCapacity(parts.count)

        for index in parts.indices {
            let isLast = index == parts.index(before: parts.endIndex)
            if isLast, hasTrailingNewline, parts[index].isEmpty {
                break
            }
            lines.append(DiffLine(
                text: parts[index],
                hasTerminatingNewline: !isLast || hasTrailingNewline
            ))
        }
        return lines
    }

    private static func mergedHunkRanges(
        around changedIndices: [Int],
        rowCount: Int,
        contextLines: Int
    ) -> [Range<Int>] {
        guard let firstChangedIndex = changedIndices.first else { return [] }

        var ranges: [Range<Int>] = []
        var currentRange = max(0, firstChangedIndex - contextLines)..<min(
            rowCount,
            firstChangedIndex + contextLines + 1
        )

        for changedIndex in changedIndices.dropFirst() {
            let nextRange = max(0, changedIndex - contextLines)..<min(
                rowCount,
                changedIndex + contextLines + 1
            )
            if nextRange.lowerBound <= currentRange.upperBound {
                currentRange = currentRange.lowerBound..<max(currentRange.upperBound, nextRange.upperBound)
            } else {
                ranges.append(currentRange)
                currentRange = nextRange
            }
        }
        ranges.append(currentRange)
        return ranges
    }

    private static func edits(from baseline: String, to changed: String) -> [TextEdit] {
        let original = Array(baseline)
        let replacement = Array(changed)
        let difference = replacement.difference(from: original)

        guard !difference.isEmpty else { return [] }

        let removedOffsets = Set(difference.removals.compactMap { change -> Int? in
            guard case .remove(let offset, _, _) = change else { return nil }
            return offset
        })
        let insertedOffsets = Set(difference.insertions.compactMap { change -> Int? in
            guard case .insert(let offset, _, _) = change else { return nil }
            return offset
        })

        var edits: [TextEdit] = []
        var originalOffset = 0
        var replacementOffset = 0
        var editStart: Int?
        var editReplacement: [Character] = []

        func finishEdit() {
            guard let editStart else { return }
            edits.append(TextEdit(
                range: editStart..<originalOffset,
                replacement: editReplacement
            ))
        }

        while originalOffset < original.count || replacementOffset < replacement.count {
            if originalOffset < original.count, removedOffsets.contains(originalOffset) {
                if editStart == nil { editStart = originalOffset }
                originalOffset += 1
                continue
            }

            if replacementOffset < replacement.count, insertedOffsets.contains(replacementOffset) {
                if editStart == nil { editStart = originalOffset }
                editReplacement.append(replacement[replacementOffset])
                replacementOffset += 1
                continue
            }

            guard originalOffset < original.count,
                  replacementOffset < replacement.count,
                  original[originalOffset] == replacement[replacementOffset] else {
                // CollectionDifference should align every remaining element.
                // Fall back to one conservative edit if that invariant ever
                // changes instead of risking an incorrect automatic merge.
                return [minimalEdit(from: original, to: replacement)]
            }

            if editStart != nil {
                finishEdit()
                editStart = nil
                editReplacement.removeAll(keepingCapacity: true)
            }
            originalOffset += 1
            replacementOffset += 1
        }

        finishEdit()
        return edits
    }

    private static func minimalEdit(
        from original: [Character],
        to replacement: [Character]
    ) -> TextEdit {
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

    private static func editsConflict(_ first: TextEdit, _ second: TextEdit) -> Bool {
        if first.range.isEmpty {
            if second.range.isEmpty {
                return first.range.lowerBound == second.range.lowerBound
            }
            return first.range.lowerBound > second.range.lowerBound
                && first.range.lowerBound < second.range.upperBound
        }
        if second.range.isEmpty {
            return second.range.lowerBound > first.range.lowerBound
                && second.range.lowerBound < first.range.upperBound
        }
        return first.range.lowerBound < second.range.upperBound
            && second.range.lowerBound < first.range.upperBound
    }

    private static func editsApplyBefore(_ first: TextEdit, _ second: TextEdit) -> Bool {
        if first.range.lowerBound != second.range.lowerBound {
            return first.range.lowerBound > second.range.lowerBound
        }
        // At the same baseline boundary, replace the original range first,
        // then insert before it. This preserves both demonstrably disjoint
        // edits without shifting the replacement range.
        return !first.range.isEmpty && second.range.isEmpty
    }
}
