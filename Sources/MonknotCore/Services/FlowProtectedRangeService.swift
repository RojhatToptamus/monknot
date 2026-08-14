import Foundation

public enum FlowSourceMode: Equatable, Sendable {
    case markdown
    case plainText
}

/// Finds source ranges that Flow and Writing Tools must not rewrite.
///
/// All input and output ranges use document-relative UTF-16 coordinates, matching
/// `NSTextView` and `NSRange`. When `enclosingRange` is supplied, returned ranges
/// are clipped to that range but remain document-relative.
public struct FlowProtectedRangeService: Sendable {
    private struct SourceLine {
        let range: NSRange
        let contentRange: NSRange
    }

    private enum FenceContainerComponent {
        case blockquote
        case listIndent(Int)
    }

    private struct Fence {
        let marker: unichar
        let length: Int
        let containerComponents: [FenceContainerComponent]
    }

    private struct FenceContainerPrefix {
        let contentStart: Int
        let blockquoteDepth: Int
        let listIndent: Int
        let components: [FenceContainerComponent]
    }

    private struct TableLineStructure {
        let trimmedRange: NSRange
        let pipes: [Int]
        let cells: [NSRange]
    }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
    private static let markdownAutolinkExpression = try! NSRegularExpression(
        pattern: #"<(?:[A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\u0000-\u0020]*|[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+)>"#
    )
    private static let inProgressURLExpression = try! NSRegularExpression(
        pattern: #"(?i)(?<![A-Z0-9+.-])(?:[A-Z][A-Z0-9+.-]*://|mailto:|www\.)[^\t\r\n <>]*|[A-Z0-9.!$%&'*+/=?^_`{|}~-]+@[A-Z0-9-]*(?:\.[A-Z0-9-]*)*"#
    )
    private static let maximumURLDetectionChunkLength = 16_384

    private struct URLDetectionUnit {
        let range: NSRange
        let protectsEntireRange: Bool
    }

    public init() {}

    public func protectedRanges(
        in text: String,
        mode: FlowSourceMode,
        intersecting enclosingRange: NSRange? = nil
    ) -> [NSRange] {
        let source = text as NSString
        guard source.length > 0, !Task.isCancelled else { return [] }

        var ranges = Self.urlRanges(in: text, source: source)
        guard !Task.isCancelled else { return [] }
        if mode == .markdown {
            let lines = Self.lines(in: source)
            guard !Task.isCancelled else { return [] }
            let links = MarkdownWorkspaceLinkParser().links(in: text)
            guard !Task.isCancelled else { return [] }
            var frontMatterRanges: [NSRange] = []
            if let frontMatterRange = Self.frontMatterRange(in: source, lines: lines) {
                ranges.append(frontMatterRange)
                frontMatterRanges.append(frontMatterRange)
            }
            guard !Task.isCancelled else { return [] }
            let fencedCodeRanges = Self.fencedCodeRanges(in: source, lines: lines)
            ranges.append(contentsOf: fencedCodeRanges)
            guard !Task.isCancelled else { return [] }
            let indentedCodeRanges = Self.indentedCodeRanges(in: source, lines: lines)
            ranges.append(contentsOf: indentedCodeRanges)
            guard !Task.isCancelled else { return [] }
            let inlineCodeRanges = Self.inlineCodeRanges(
                in: source,
                excluding: fencedCodeRanges + indentedCodeRanges
            )
            ranges.append(contentsOf: inlineCodeRanges)
            guard !Task.isCancelled else { return [] }
            let codeExcludedRanges = frontMatterRanges + fencedCodeRanges +
                indentedCodeRanges + inlineCodeRanges
            ranges.append(contentsOf: Self.markdownDestinationRanges(
                in: source,
                lines: lines,
                excluding: codeExcludedRanges
            ))
            guard !Task.isCancelled else { return [] }
            ranges.append(contentsOf: Self.markdownSyntaxRanges(in: source, lines: lines, links: links))
            guard !Task.isCancelled else { return [] }
            ranges.append(contentsOf: links.map { $0.destinationRange.nsRange })
            ranges.append(contentsOf: Self.markdownAutolinkExpression.matches(
                in: text,
                range: NSRange(location: 0, length: source.length)
            ).map(\.range))
            guard !Task.isCancelled else { return [] }
            ranges.append(contentsOf: Self.htmlRanges(
                in: source,
                excluding: codeExcludedRanges
            ))
            guard !Task.isCancelled else { return [] }
        }

        let merged = Self.merged(ranges, documentLength: source.length)
        guard !Task.isCancelled else { return [] }
        guard let enclosingRange else { return merged }
        guard let enclosingRange = Self.bounded(enclosingRange, documentLength: source.length) else {
            return []
        }
        return merged.compactMap { range in
            let intersection = NSIntersectionRange(range, enclosingRange)
            return intersection.length > 0 ? intersection : nil
        }
    }

    private static func urlRanges(in text: String, source: NSString) -> [NSRange] {
        let units = urlDetectionUnits(in: source)
        guard !Task.isCancelled else { return [] }

        var ranges: [NSRange] = []
        for unit in units {
            guard !Task.isCancelled else { return [] }
            if unit.protectsEntireRange {
                ranges.append(unit.range)
                continue
            }
            if let linkDetector {
                ranges.append(contentsOf: linkDetector.matches(
                    in: text,
                    options: [],
                    range: unit.range
                ).map(\.range))
            }
            guard !Task.isCancelled else { return [] }
            ranges.append(contentsOf: inProgressURLExpression.matches(
                in: text,
                range: unit.range
            ).map(\.range))
        }
        return ranges
    }

    /// Foundation's link detector and regular-expression matcher do not observe
    /// Swift task cancellation while one match call is running. Split at URL-safe
    /// whitespace boundaries so each uncancellable call has a small upper bound.
    /// A single oversized non-whitespace token is inspected with a linear scanner;
    /// URL-shaped tokens are conservatively protected as a whole.
    private static func urlDetectionUnits(in source: NSString) -> [URLDetectionUnit] {
        var units: [URLDetectionUnit] = []
        var chunkStart = NSNotFound
        var chunkEnd = 0
        var location = 0

        func appendChunk() {
            guard chunkStart != NSNotFound, chunkEnd > chunkStart else { return }
            units.append(URLDetectionUnit(
                range: NSRange(location: chunkStart, length: chunkEnd - chunkStart),
                protectsEntireRange: false
            ))
            chunkStart = NSNotFound
            chunkEnd = 0
        }

        while location < source.length {
            if cancellationCheckpoint(at: location) { return [] }
            while location < source.length,
                  isURLTokenBoundary(source.character(at: location)) {
                location += 1
                if cancellationCheckpoint(at: location) { return [] }
            }
            guard location < source.length else { break }

            let tokenStart = location
            var hasDot = false
            var hasAtSign = false
            var hasSchemeSeparator = false
            var previousCharacter: unichar?
            var characterBeforePrevious: unichar?
            while location < source.length,
                  !isURLTokenBoundary(source.character(at: location)) {
                let character = source.character(at: location)
                hasDot = hasDot || character == 0x2E
                hasAtSign = hasAtSign || character == 0x40
                if characterBeforePrevious == 0x3A,
                   previousCharacter == 0x2F,
                   character == 0x2F {
                    hasSchemeSeparator = true
                }
                characterBeforePrevious = previousCharacter
                previousCharacter = character
                location += 1
                if cancellationCheckpoint(at: location) { return [] }
            }
            let tokenRange = NSRange(location: tokenStart, length: location - tokenStart)

            if tokenRange.length > maximumURLDetectionChunkLength {
                appendChunk()
                if hasSchemeSeparator || hasAtSign || hasDot {
                    units.append(URLDetectionUnit(
                        range: tokenRange,
                        protectsEntireRange: true
                    ))
                }
                continue
            }

            if chunkStart == NSNotFound {
                chunkStart = tokenStart
            } else if NSMaxRange(tokenRange) - chunkStart > maximumURLDetectionChunkLength {
                appendChunk()
                chunkStart = tokenStart
            }
            chunkEnd = NSMaxRange(tokenRange)
        }
        appendChunk()
        return units
    }

    private static func isURLTokenBoundary(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func lines(in source: NSString) -> [SourceLine] {
        var result: [SourceLine] = []
        var location = 0
        while location < source.length {
            if cancellationCheckpoint(at: location) { break }
            var start = 0
            var end = 0
            var contentsEnd = 0
            source.getLineStart(
                &start,
                end: &end,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            guard end > location else { break }
            result.append(SourceLine(
                range: NSRange(location: start, length: end - start),
                contentRange: NSRange(location: start, length: contentsEnd - start)
            ))
            location = end
        }
        return result
    }

    private static func frontMatterRange(in source: NSString, lines: [SourceLine]) -> NSRange? {
        guard let first = lines.first else { return nil }
        var opening = source.substring(with: first.contentRange)
        if opening.hasPrefix("\u{FEFF}") {
            opening.removeFirst()
        }
        let openingMarker: String
        if isFrontMatterMarker(opening, allowedMarkers: ["---"]) {
            openingMarker = "---"
        } else if isFrontMatterMarker(opening, allowedMarkers: ["+++"]) {
            openingMarker = "+++"
        } else {
            return nil
        }

        var hasBodyEvidence = false
        for line in lines.dropFirst() {
            guard !Task.isCancelled else { return nil }
            let marker = source.substring(with: line.contentRange)
            let closingMarkers: Set<String> = openingMarker == "---" ? ["---", "..."] : ["+++"]
            if isFrontMatterMarker(marker, allowedMarkers: closingMarkers) {
                return NSRange(location: 0, length: NSMaxRange(line.range))
            }
            if looksLikeFrontMatterBodyLine(marker, marker: openingMarker) {
                hasBodyEvidence = true
            }
        }

        guard hasBodyEvidence else { return nil }
        return NSRange(location: 0, length: source.length)
    }

    private static func looksLikeFrontMatterBodyLine(_ line: String, marker: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
        if marker == "+++" {
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") { return true }
            guard let separator = trimmed.firstIndex(of: "=") else { return false }
            return trimmed[..<separator].contains { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        }

        guard let separator = trimmed.firstIndex(of: ":") else { return false }
        let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
        return !key.isEmpty && key.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "."
        }
    }

    private static func isFrontMatterMarker(
        _ line: String,
        allowedMarkers: Set<String>
    ) -> Bool {
        for marker in allowedMarkers where line.hasPrefix(marker) {
            let suffix = line.dropFirst(marker.count)
            if suffix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                return true
            }
        }
        return false
    }

    private static func fencedCodeRanges(in source: NSString, lines: [SourceLine]) -> [NSRange] {
        var result: [NSRange] = []
        var lineIndex = 0

        while lineIndex < lines.count {
            guard !Task.isCancelled else { break }
            let line = lines[lineIndex]
            guard let opening = openingFence(in: source, range: line.contentRange) else {
                lineIndex += 1
                continue
            }

            var closingIndex: Int?
            var containerExitIndex: Int?
            var candidateIndex = lineIndex + 1
            while candidateIndex < lines.count {
                guard !Task.isCancelled else { return result }
                guard isInsideFenceContainer(
                    source: source,
                    range: lines[candidateIndex].contentRange,
                    opening: opening
                ) else {
                    containerExitIndex = candidateIndex
                    break
                }
                if isClosingFence(
                    in: source,
                    range: lines[candidateIndex].contentRange,
                    opening: opening
                ) {
                    closingIndex = candidateIndex
                    break
                }
                candidateIndex += 1
            }

            if let closingIndex {
                let upperBound = NSMaxRange(lines[closingIndex].range)
                result.append(NSRange(location: line.range.location, length: upperBound - line.range.location))
                lineIndex = closingIndex + 1
            } else if let containerExitIndex {
                let upperBound = lines[containerExitIndex].range.location
                result.append(NSRange(location: line.range.location, length: upperBound - line.range.location))
                lineIndex = containerExitIndex
            } else {
                result.append(NSRange(location: line.range.location, length: source.length - line.range.location))
                break
            }
        }
        return result
    }

    private static func indentedCodeRanges(in source: NSString, lines: [SourceLine]) -> [NSRange] {
        var result: [NSRange] = []
        var previousWasBlank = true
        var previousWasNonParagraphBlock = false
        var isInsideIndentedCode = false
        var previousBlockquoteDepth = 0
        var activeListContext: (blockquoteDepth: Int, contentIndent: Int)?

        for line in lines {
            guard !Task.isCancelled else { break }
            let prefix = fenceContainerPrefix(in: source, range: line.contentRange)
            let isBlank = trimmedHorizontalWhitespaceRange(
                NSRange(
                    location: prefix.contentStart,
                    length: NSMaxRange(line.contentRange) - prefix.contentStart
                ),
                in: source
            ).length == 0
            guard !isBlank else {
                previousWasBlank = true
                previousWasNonParagraphBlock = false
                if activeListContext?.blockquoteDepth != prefix.blockquoteDepth {
                    activeListContext = nil
                }
                previousBlockquoteDepth = prefix.blockquoteDepth
                continue
            }

            var codeContentStart = prefix.contentStart
            if prefix.listIndent > 0 {
                activeListContext = (prefix.blockquoteDepth, prefix.listIndent)
            } else if let listContext = activeListContext,
                      listContext.blockquoteDepth == prefix.blockquoteDepth {
                var remainingIndent = listContext.contentIndent
                while remainingIndent > 0,
                      codeContentStart < NSMaxRange(line.contentRange),
                      source.character(at: codeContentStart) == 32 {
                    codeContentStart += 1
                    remainingIndent -= 1
                }
                if remainingIndent > 0 {
                    activeListContext = nil
                    codeContentStart = prefix.contentStart
                }
            } else {
                activeListContext = nil
            }

            let codeContentRange = NSRange(
                location: codeContentStart,
                length: NSMaxRange(line.contentRange) - codeContentStart
            )
            let isIndented = hasCodeIndentation(codeContentRange, in: source)
            let startsBlockquote = prefix.blockquoteDepth > 0 &&
                prefix.blockquoteDepth != previousBlockquoteDepth
            let startsListItem = prefix.listIndent > 0
            if isIndented,
               previousWasBlank || previousWasNonParagraphBlock || isInsideIndentedCode ||
                startsBlockquote || startsListItem {
                result.append(line.range)
                isInsideIndentedCode = true
            } else {
                isInsideIndentedCode = false
            }
            previousWasNonParagraphBlock = isNonParagraphBlockBoundary(
                in: source,
                range: line.contentRange
            )
            previousWasBlank = false
            previousBlockquoteDepth = prefix.blockquoteDepth
        }
        return result
    }

    private static func hasCodeIndentation(_ range: NSRange, in source: NSString) -> Bool {
        guard range.length > 0 else { return false }
        if source.character(at: range.location) == 9 { return true }
        guard range.length >= 4 else { return false }
        return (0..<4).allSatisfy { source.character(at: range.location + $0) == 32 }
    }

    private static func isNonParagraphBlockBoundary(
        in source: NSString,
        range: NSRange
    ) -> Bool {
        let prefix = fenceContainerPrefix(in: source, range: range)
        let upperBound = NSMaxRange(range)
        var index = skipUpToThreeSpaces(
            from: prefix.contentStart,
            upperBound: upperBound,
            in: source
        )
        guard index < upperBound else { return false }

        let remainder = trimmedHorizontalWhitespaceRange(
            NSRange(location: index, length: upperBound - index),
            in: source
        )
        if isThematicOrSetextMarker(remainder, in: source) ||
            openingFence(in: source, range: range) != nil ||
            referenceDefinitionLabelRange(
                startingAt: index,
                upperBound: upperBound,
                in: source
            ) != nil {
            return true
        }

        guard source.character(at: index) == 35 else { return false }
        let markerStart = index
        while index < upperBound, source.character(at: index) == 35 {
            index += 1
        }
        return index - markerStart <= 6 &&
            (index == upperBound || isHorizontalWhitespace(source.character(at: index)))
    }

    private static func openingFence(in source: NSString, range: NSRange) -> Fence? {
        let prefix = fenceContainerPrefix(in: source, range: range)
        var index = prefix.contentStart
        let upperBound = NSMaxRange(range)
        var indentation = 0
        while index < upperBound, indentation < 4, source.character(at: index) == 32 {
            indentation += 1
            index += 1
        }
        guard indentation <= 3, index < upperBound else { return nil }

        let marker = source.character(at: index)
        guard marker == 96 || marker == 126 else { return nil }
        let markerStart = index
        while index < upperBound, source.character(at: index) == marker {
            if cancellationCheckpoint(at: index) { return nil }
            index += 1
        }
        let length = index - markerStart
        guard length >= 3 else { return nil }

        if marker == 96 {
            while index < upperBound {
                if cancellationCheckpoint(at: index) { return nil }
                guard source.character(at: index) != 96 else { return nil }
                index += 1
            }
        }
        return Fence(
            marker: marker,
            length: length,
            containerComponents: prefix.components
        )
    }

    private static func isClosingFence(
        in source: NSString,
        range: NSRange,
        opening: Fence
    ) -> Bool {
        guard var index = fenceContainerContentStart(
            in: source,
            range: range,
            opening: opening,
            allowingBlankLine: false
        ) else { return false }
        let upperBound = NSMaxRange(range)
        var indentation = 0
        while index < upperBound, indentation < 4, source.character(at: index) == 32 {
            indentation += 1
            index += 1
        }
        guard indentation <= 3, index < upperBound else { return false }

        var markerLength = 0
        while index < upperBound, source.character(at: index) == opening.marker {
            if cancellationCheckpoint(at: index) { return false }
            markerLength += 1
            index += 1
        }
        guard markerLength >= opening.length else { return false }
        while index < upperBound {
            if cancellationCheckpoint(at: index) { return false }
            let character = source.character(at: index)
            guard character == 32 || character == 9 else { return false }
            index += 1
        }
        return true
    }

    private static func isInsideFenceContainer(
        source: NSString,
        range: NSRange,
        opening: Fence
    ) -> Bool {
        guard !opening.containerComponents.isEmpty else { return true }
        return fenceContainerContentStart(
            in: source,
            range: range,
            opening: opening,
            allowingBlankLine: true
        ) != nil
    }

    private static func fenceContainerContentStart(
        in source: NSString,
        range: NSRange,
        opening: Fence,
        allowingBlankLine: Bool
    ) -> Int? {
        var index = range.location
        let upperBound = NSMaxRange(range)

        for component in opening.containerComponents {
            switch component {
            case .blockquote:
                let markerStart = skipUpToThreeSpaces(
                    from: index,
                    upperBound: upperBound,
                    in: source
                )
                guard markerStart < upperBound, source.character(at: markerStart) == 62 else {
                    return nil
                }
                index = markerStart + 1
                if index < upperBound, isHorizontalWhitespace(source.character(at: index)) {
                    index += 1
                }
            case .listIndent(let indent):
                if allowingBlankLine,
                   trimmedHorizontalWhitespaceRange(
                       NSRange(location: index, length: upperBound - index),
                       in: source
                   ).length == 0 {
                    return index
                }
                var remainingIndent = indent
                while remainingIndent > 0,
                      index < upperBound,
                      source.character(at: index) == 32 {
                    index += 1
                    remainingIndent -= 1
                }
                guard remainingIndent == 0 else { return nil }
            }
        }
        return index
    }

    private static func fenceContainerPrefix(
        in source: NSString,
        range: NSRange
    ) -> FenceContainerPrefix {
        var index = range.location
        let upperBound = NSMaxRange(range)
        var blockquoteDepth = 0
        var listIndent = 0
        var components: [FenceContainerComponent] = []
        var foundContainer = false

        while index < upperBound {
            if cancellationCheckpoint(at: index) { break }
            let segmentStart = index
            let markerStart = skipUpToThreeSpaces(
                from: segmentStart,
                upperBound: upperBound,
                in: source
            )
            guard markerStart < upperBound else { break }

            if source.character(at: markerStart) == 62 {
                foundContainer = true
                blockquoteDepth += 1
                components.append(.blockquote)
                index = markerStart + 1
                if index < upperBound, isHorizontalWhitespace(source.character(at: index)) {
                    index += 1
                }
                continue
            }

            guard let markerEnd = listMarkerUpperBound(
                startingAt: markerStart,
                upperBound: upperBound,
                in: source
            ) else { break }
            foundContainer = true
            let contentStart = containerListPaddingUpperBound(
                from: markerEnd,
                upperBound: upperBound,
                in: source
            )
            let indent = contentStart - segmentStart
            listIndent += indent
            components.append(.listIndent(indent))
            index = contentStart
        }

        return FenceContainerPrefix(
            contentStart: foundContainer ? index : range.location,
            blockquoteDepth: blockquoteDepth,
            listIndent: listIndent,
            components: components
        )
    }

    private static func containerListPaddingUpperBound(
        from start: Int,
        upperBound: Int,
        in source: NSString
    ) -> Int {
        guard start < upperBound else { return start }
        if source.character(at: start) == 9 { return start + 1 }

        var end = start
        while end < upperBound, source.character(at: end) == 32 {
            end += 1
        }
        let spaceCount = end - start
        return spaceCount > 4 ? start + 1 : end
    }

    private static func inlineCodeRanges(
        in source: NSString,
        excluding excludedRanges: [NSRange]
    ) -> [NSRange] {
        var result: [NSRange] = []
        var index = 0
        let excludedRanges = excludedRanges.sorted { $0.location < $1.location }
        var excludedIndex = 0

        while index < source.length {
            if cancellationCheckpoint(at: index) { break }
            while excludedIndex < excludedRanges.count,
                  NSMaxRange(excludedRanges[excludedIndex]) <= index {
                excludedIndex += 1
            }
            if excludedIndex < excludedRanges.count,
               NSLocationInRange(index, excludedRanges[excludedIndex]) {
                index = NSMaxRange(excludedRanges[excludedIndex])
                continue
            }
            guard source.character(at: index) == 96, !isEscaped(index, in: source) else {
                index += 1
                continue
            }
            let openingStart = index
            while index < source.length, source.character(at: index) == 96 {
                index += 1
            }
            let delimiterLength = index - openingStart
            var candidate = index
            var closingEnd: Int?

            while candidate < source.length {
                if cancellationCheckpoint(at: candidate) { return result }
                while excludedIndex < excludedRanges.count,
                      NSMaxRange(excludedRanges[excludedIndex]) <= candidate {
                    excludedIndex += 1
                }
                if excludedIndex < excludedRanges.count,
                   NSLocationInRange(candidate, excludedRanges[excludedIndex]) {
                    candidate = NSMaxRange(excludedRanges[excludedIndex])
                    continue
                }
                guard source.character(at: candidate) == 96, !isEscaped(candidate, in: source) else {
                    candidate += 1
                    continue
                }
                let candidateStart = candidate
                while candidate < source.length, source.character(at: candidate) == 96 {
                    candidate += 1
                }
                if candidate - candidateStart == delimiterLength {
                    closingEnd = candidate
                    break
                }
            }

            if let closingEnd {
                result.append(NSRange(location: openingStart, length: closingEnd - openingStart))
                index = closingEnd
            } else {
                result.append(NSRange(
                    location: openingStart,
                    length: source.length - openingStart
                ))
                break
            }
        }
        return result
    }

    /// Handles both complete and in-progress destinations. Unlike the workspace
    /// link parser, this scan deliberately balances nested and escaped parentheses.
    private static func markdownDestinationRanges(
        in source: NSString,
        lines: [SourceLine],
        excluding excludedRanges: [NSRange]
    ) -> [NSRange] {
        var result: [NSRange] = []
        let excludedRanges = excludedRanges.sorted { $0.location < $1.location }
        var excludedIndex = 0

        for line in lines {
            guard !Task.isCancelled else { break }
            var index = line.contentRange.location
            let upperBound = NSMaxRange(line.contentRange)
            while index < upperBound {
                if cancellationCheckpoint(at: index) { return result }
                while excludedIndex < excludedRanges.count,
                      NSMaxRange(excludedRanges[excludedIndex]) <= index {
                    excludedIndex += 1
                }
                if excludedIndex < excludedRanges.count,
                   NSLocationInRange(index, excludedRanges[excludedIndex]) {
                    index = min(NSMaxRange(excludedRanges[excludedIndex]), upperBound)
                    continue
                }
                guard !isEscaped(index, in: source) else {
                    index += 1
                    continue
                }

                if index + 1 < upperBound,
                   source.character(at: index) == 91,
                   source.character(at: index + 1) == 91 {
                    var cursor = index + 2
                    var closingStart: Int?
                    while cursor + 1 < upperBound {
                        if cancellationCheckpoint(at: cursor) { return result }
                        if !isEscaped(cursor, in: source),
                           source.character(at: cursor) == 93,
                           source.character(at: cursor + 1) == 93 {
                            closingStart = cursor
                            break
                        }
                        cursor += 1
                    }
                    guard let closingStart else {
                        result.append(NSRange(location: index, length: upperBound - index))
                        break
                    }
                    let end = closingStart + 2
                    var aliasSeparator: Int?
                    var aliasCandidate = index + 2
                    while aliasCandidate < closingStart {
                        if cancellationCheckpoint(at: aliasCandidate) { return result }
                        if source.character(at: aliasCandidate) == 124,
                           !isEscaped(aliasCandidate, in: source) {
                            aliasSeparator = aliasCandidate
                            break
                        }
                        aliasCandidate += 1
                    }
                    if let aliasSeparator {
                        result.append(NSRange(location: index, length: 2))
                        if aliasSeparator > index + 2 {
                            result.append(NSRange(
                                location: index + 2,
                                length: aliasSeparator - index - 2
                            ))
                        }
                        result.append(NSRange(location: aliasSeparator, length: 1))
                        result.append(NSRange(location: closingStart, length: 2))
                    } else {
                        result.append(NSRange(location: index, length: end - index))
                    }
                    index = end
                    continue
                }

                if index + 1 < upperBound,
                   source.character(at: index) == 93,
                   source.character(at: index + 1) == 40 {
                    guard let openingBracket = nearestOpeningBracket(
                        before: index,
                        lowerBound: line.contentRange.location,
                        in: source
                    ) else {
                        index += 2
                        continue
                    }
                    var cursor = index + 2
                    var depth = 1
                    while cursor < upperBound, depth > 0 {
                        if cancellationCheckpoint(at: cursor) { return result }
                        if !isEscaped(cursor, in: source) {
                            let character = source.character(at: cursor)
                            if character == 40 {
                                depth += 1
                            } else if character == 41 {
                                depth -= 1
                            }
                        }
                        cursor += 1
                    }
                    let end = depth == 0 ? cursor : upperBound
                    result.append(NSRange(location: index, length: end - index))
                    result.append(NSRange(location: openingBracket, length: 1))
                    if openingBracket > line.contentRange.location,
                       source.character(at: openingBracket - 1) == 33,
                       !isEscaped(openingBracket - 1, in: source) {
                        result.append(NSRange(location: openingBracket - 1, length: 1))
                    }
                    guard depth == 0 else { break }
                    index = end
                    continue
                }

                index += 1
            }
        }
        return result
    }

    private static func nearestOpeningBracket(
        before location: Int,
        lowerBound: Int,
        in source: NSString
    ) -> Int? {
        guard location > lowerBound else { return nil }
        var index = location - 1
        var nestedClosingBrackets = 0
        while index >= lowerBound {
            if cancellationCheckpoint(at: index) { return nil }
            let character = source.character(at: index)
            if character == 91, !isEscaped(index, in: source) {
                if nestedClosingBrackets == 0 { return index }
                nestedClosingBrackets -= 1
            }
            if character == 93, !isEscaped(index, in: source) {
                nestedClosingBrackets += 1
            }
            if index == lowerBound { break }
            index -= 1
        }
        return nil
    }

    private static func markdownSyntaxRanges(
        in source: NSString,
        lines: [SourceLine],
        links: [MarkdownWorkspaceLink]
    ) -> [NSRange] {
        var result: [NSRange] = []

        result.append(contentsOf: markdownLineSyntaxRanges(in: source, lines: lines))
        guard !Task.isCancelled else { return result }
        result.append(contentsOf: inlineDelimiterRanges(in: source, lines: lines))
        guard !Task.isCancelled else { return result }
        result.append(contentsOf: footnoteIdentifierRanges(in: source, lines: lines))
        guard !Task.isCancelled else { return result }
        result.append(contentsOf: escapedMarkdownRanges(in: source))
        guard !Task.isCancelled else { return result }
        result.append(contentsOf: tableDelimiterRanges(in: source, lines: lines))
        guard !Task.isCancelled else { return result }

        let linkMarkers: Set<unichar> = [33, 40, 41, 58, 91, 93, 124]
        for link in links {
            guard !Task.isCancelled else { break }
            let range = link.sourceRange.nsRange
            var index = range.location
            while index < NSMaxRange(range) {
                if cancellationCheckpoint(at: index) { return result }
                guard linkMarkers.contains(source.character(at: index)) else {
                    index += 1
                    continue
                }
                let start = index
                while index < NSMaxRange(range), linkMarkers.contains(source.character(at: index)) {
                    index += 1
                }
                result.append(NSRange(location: start, length: index - start))
            }
        }
        return result
    }

    private static func markdownLineSyntaxRanges(
        in source: NSString,
        lines: [SourceLine]
    ) -> [NSRange] {
        var result: [NSRange] = []
        for line in lines {
            guard !Task.isCancelled else { break }
            let lowerBound = line.contentRange.location
            let upperBound = NSMaxRange(line.contentRange)
            guard lowerBound < upperBound else { continue }

            let trimmed = trimmedHorizontalWhitespaceRange(line.contentRange, in: source)
            if isThematicOrSetextMarker(trimmed, in: source) {
                result.append(trimmed)
                continue
            }

            var index = skipUpToThreeSpaces(from: lowerBound, upperBound: upperBound, in: source)
            while index < upperBound {
                if source.character(at: index) == 62 {
                    result.append(NSRange(location: index, length: 1))
                    index = skipUpToThreeSpaces(
                        from: index + 1,
                        upperBound: upperBound,
                        in: source
                    )
                    continue
                }

                guard let markerEnd = listMarkerUpperBound(
                    startingAt: index,
                    upperBound: upperBound,
                    in: source
                ) else { break }
                result.append(NSRange(location: index, length: markerEnd - index))
                index = skipListPadding(from: markerEnd, upperBound: upperBound, in: source)

                if isTaskListMarker(startingAt: index, upperBound: upperBound, in: source) {
                    result.append(NSRange(location: index, length: 3))
                    index = skipHorizontalWhitespace(
                        from: index + 3,
                        upperBound: upperBound,
                        in: source
                    )
                }
            }

            guard index < upperBound else { continue }
            let remainder = trimmedHorizontalWhitespaceRange(
                NSRange(location: index, length: upperBound - index),
                in: source
            )
            if isThematicOrSetextMarker(remainder, in: source) {
                result.append(remainder)
                continue
            }

            if source.character(at: index) == 35 {
                let start = index
                while index < upperBound, source.character(at: index) == 35 {
                    if cancellationCheckpoint(at: index) { return result }
                    index += 1
                }
                if index - start <= 6,
                   index == upperBound || isHorizontalWhitespace(source.character(at: index)) {
                    result.append(NSRange(location: start, length: index - start))
                    if let closing = closingATXMarkerRange(
                        after: index,
                        upperBound: upperBound,
                        in: source
                    ) {
                        result.append(closing)
                    }
                }
                continue
            }

            if let definitionLabel = referenceDefinitionLabelRange(
                startingAt: index,
                upperBound: upperBound,
                in: source
            ) {
                result.append(definitionLabel)
            }
        }
        return result
    }

    private static func skipUpToThreeSpaces(
        from start: Int,
        upperBound: Int,
        in source: NSString
    ) -> Int {
        var index = start
        var count = 0
        while index < upperBound, count < 3, source.character(at: index) == 32 {
            index += 1
            count += 1
        }
        if index < upperBound, source.character(at: index) == 9 {
            index += 1
        }
        return index
    }

    private static func skipListPadding(
        from start: Int,
        upperBound: Int,
        in source: NSString
    ) -> Int {
        var index = start
        var count = 0
        while index < upperBound, count < 4, source.character(at: index) == 32 {
            index += 1
            count += 1
        }
        if index < upperBound, source.character(at: index) == 9 {
            index += 1
        }
        return index
    }

    private static func skipHorizontalWhitespace(
        from start: Int,
        upperBound: Int,
        in source: NSString
    ) -> Int {
        var index = start
        while index < upperBound, isHorizontalWhitespace(source.character(at: index)) {
            if cancellationCheckpoint(at: index) { break }
            index += 1
        }
        return index
    }

    private static func listMarkerUpperBound(
        startingAt start: Int,
        upperBound: Int,
        in source: NSString
    ) -> Int? {
        guard start < upperBound else { return nil }
        let marker = source.character(at: start)
        if marker == 42 || marker == 43 || marker == 45 {
            let end = start + 1
            return end == upperBound || isHorizontalWhitespace(source.character(at: end))
                ? end
                : nil
        }

        guard marker >= 48, marker <= 57 else { return nil }
        var index = start
        while index < upperBound,
              index - start < 9,
              source.character(at: index) >= 48,
              source.character(at: index) <= 57 {
            index += 1
        }
        guard index < upperBound,
              (source.character(at: index) == 46 || source.character(at: index) == 41)
        else { return nil }
        let end = index + 1
        return end == upperBound || isHorizontalWhitespace(source.character(at: end))
            ? end
            : nil
    }

    private static func isTaskListMarker(
        startingAt start: Int,
        upperBound: Int,
        in source: NSString
    ) -> Bool {
        guard start + 2 < upperBound,
              source.character(at: start) == 91,
              source.character(at: start + 2) == 93
        else { return false }
        let state = source.character(at: start + 1)
        guard state == 32 || state == 120 || state == 88 else { return false }
        return start + 3 == upperBound || isHorizontalWhitespace(source.character(at: start + 3))
    }

    private static func closingATXMarkerRange(
        after openingEnd: Int,
        upperBound: Int,
        in source: NSString
    ) -> NSRange? {
        var end = upperBound
        while end > openingEnd, isHorizontalWhitespace(source.character(at: end - 1)) {
            if cancellationCheckpoint(at: end) { return nil }
            end -= 1
        }
        var start = end
        while start > openingEnd, source.character(at: start - 1) == 35 {
            if cancellationCheckpoint(at: start) { return nil }
            start -= 1
        }
        guard start < end,
              start > openingEnd,
              isHorizontalWhitespace(source.character(at: start - 1))
        else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static func referenceDefinitionLabelRange(
        startingAt start: Int,
        upperBound: Int,
        in source: NSString
    ) -> NSRange? {
        guard start < upperBound,
              source.character(at: start) == 91,
              !isEscaped(start, in: source)
        else { return nil }
        var index = start + 1
        while index < upperBound {
            if cancellationCheckpoint(at: index) { return nil }
            if source.character(at: index) == 93, !isEscaped(index, in: source) {
                guard index > start + 1,
                      index + 1 < upperBound,
                      source.character(at: index + 1) == 58
                else { return nil }
                return NSRange(location: start, length: index + 2 - start)
            }
            index += 1
        }
        return nil
    }

    private static func inlineDelimiterRanges(
        in source: NSString,
        lines: [SourceLine]
    ) -> [NSRange] {
        var result: [NSRange] = []
        for line in lines {
            guard !Task.isCancelled else { break }
            var index = line.contentRange.location
            let upperBound = NSMaxRange(line.contentRange)
            while index < upperBound {
                if cancellationCheckpoint(at: index) { return result }
                let marker = source.character(at: index)
                guard (marker == 42 || marker == 95 || marker == 126),
                      !isEscaped(index, in: source)
                else {
                    index += 1
                    continue
                }
                let start = index
                while index < upperBound, source.character(at: index) == marker {
                    if cancellationCheckpoint(at: index) { return result }
                    index += 1
                }
                let length = index - start
                guard (marker == 126 && length == 2) ||
                        marker == 42 || marker == 95
                else { continue }

                let previousIsWord = start > line.contentRange.location &&
                    isWordCharacter(source.character(at: start - 1))
                let nextIsWord = index < upperBound && isWordCharacter(source.character(at: index))
                if marker == 95, previousIsWord, nextIsWord {
                    continue
                }
                let previousIsWhitespace = start == line.contentRange.location ||
                    isHorizontalWhitespace(source.character(at: start - 1))
                let nextIsWhitespace = index == upperBound ||
                    isHorizontalWhitespace(source.character(at: index))
                guard !(previousIsWhitespace && nextIsWhitespace) else { continue }
                result.append(NSRange(location: start, length: length))
            }
        }
        return result
    }

    private static func footnoteIdentifierRanges(
        in source: NSString,
        lines: [SourceLine]
    ) -> [NSRange] {
        var result: [NSRange] = []
        for line in lines {
            guard !Task.isCancelled else { break }
            var index = line.contentRange.location
            let upperBound = NSMaxRange(line.contentRange)
            while index + 2 < upperBound {
                if cancellationCheckpoint(at: index) { return result }
                guard source.character(at: index) == 91,
                      source.character(at: index + 1) == 94,
                      !isEscaped(index, in: source)
                else {
                    index += 1
                    continue
                }

                var closing = index + 2
                while closing < upperBound,
                      source.character(at: closing) != 93 || isEscaped(closing, in: source) {
                    if cancellationCheckpoint(at: closing) { return result }
                    closing += 1
                }
                guard closing < upperBound, closing > index + 2 else {
                    index += 2
                    continue
                }
                result.append(NSRange(location: index, length: closing + 1 - index))
                index = closing + 1
            }
        }
        return result
    }

    private static func escapedMarkdownRanges(in source: NSString) -> [NSRange] {
        let escapable: Set<unichar> = [
            33, 35, 40, 41, 42, 43, 45, 46, 62, 91, 92, 93, 95, 96, 123, 124, 125, 126,
        ]
        var result: [NSRange] = []
        var index = 0
        while index + 1 < source.length {
            if cancellationCheckpoint(at: index) { break }
            if source.character(at: index) == 92,
               !isEscaped(index, in: source),
               escapable.contains(source.character(at: index + 1)) {
                result.append(NSRange(location: index, length: 2))
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }

    private static func tableDelimiterRanges(
        in source: NSString,
        lines: [SourceLine]
    ) -> [NSRange] {
        var result: [NSRange] = []
        var lineIndex = 1
        while lineIndex < lines.count {
            guard !Task.isCancelled else { break }
            guard let separator = tableLineStructure(for: lines[lineIndex], in: source),
                  separator.cells.allSatisfy({ isTableSeparatorCell($0, in: source) }),
                  let header = tableLineStructure(for: lines[lineIndex - 1], in: source),
                  header.cells.count == separator.cells.count
            else {
                lineIndex += 1
                continue
            }

            result.append(contentsOf: header.pipes.map { NSRange(location: $0, length: 1) })
            result.append(separator.trimmedRange)

            var bodyIndex = lineIndex + 1
            while bodyIndex < lines.count {
                guard !Task.isCancelled else { return result }
                let line = lines[bodyIndex]
                guard trimmedHorizontalWhitespaceRange(line.contentRange, in: source).length > 0,
                      let body = tableLineStructure(for: line, in: source)
                else { break }
                result.append(contentsOf: body.pipes.map { NSRange(location: $0, length: 1) })
                bodyIndex += 1
            }
            lineIndex = bodyIndex
        }
        return result
    }

    private static func tableLineStructure(
        for line: SourceLine,
        in source: NSString
    ) -> TableLineStructure? {
        let trimmed = trimmedHorizontalWhitespaceRange(line.contentRange, in: source)
        guard trimmed.length > 0 else { return nil }

        var pipes: [Int] = []
        var index = trimmed.location
        while index < NSMaxRange(trimmed) {
            if cancellationCheckpoint(at: index) { return nil }
            if source.character(at: index) == 124, !isEscaped(index, in: source) {
                pipes.append(index)
            }
            index += 1
        }
        guard !pipes.isEmpty else { return nil }

        var cells: [NSRange] = []
        var cellStart = trimmed.location
        for pipe in pipes {
            cells.append(NSRange(location: cellStart, length: pipe - cellStart))
            cellStart = pipe + 1
        }
        cells.append(NSRange(location: cellStart, length: NSMaxRange(trimmed) - cellStart))
        if pipes.first == trimmed.location {
            cells.removeFirst()
        }
        if pipes.last == NSMaxRange(trimmed) - 1 {
            cells.removeLast()
        }
        guard cells.count >= 2 else { return nil }
        return TableLineStructure(trimmedRange: trimmed, pipes: pipes, cells: cells)
    }

    private static func isTableSeparatorCell(_ range: NSRange, in source: NSString) -> Bool {
        let trimmed = trimmedHorizontalWhitespaceRange(range, in: source)
        guard trimmed.length > 0 else { return false }
        var start = trimmed.location
        var end = NSMaxRange(trimmed)
        if source.character(at: start) == 58 {
            start += 1
        }
        if end > start, source.character(at: end - 1) == 58 {
            end -= 1
        }
        guard end - start >= 3 else { return false }
        for index in start..<end {
            if cancellationCheckpoint(at: index) { return false }
            guard source.character(at: index) == 45 else { return false }
        }
        return true
    }

    private static func trimmedHorizontalWhitespaceRange(
        _ range: NSRange,
        in source: NSString
    ) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isHorizontalWhitespace(source.character(at: start)) {
            if cancellationCheckpoint(at: start) { break }
            start += 1
        }
        while end > start, isHorizontalWhitespace(source.character(at: end - 1)) {
            if cancellationCheckpoint(at: end) { break }
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    private static func isThematicOrSetextMarker(_ range: NSRange, in source: NSString) -> Bool {
        guard range.length > 0 else { return false }
        var marker: unichar?
        var markerCount = 0
        for index in range.location..<NSMaxRange(range) {
            if cancellationCheckpoint(at: index) { return false }
            let character = source.character(at: index)
            if isHorizontalWhitespace(character) { continue }
            guard character == 42 || character == 45 || character == 95 || character == 61 else {
                return false
            }
            if let marker, marker != character { return false }
            marker = character
            markerCount += 1
        }
        guard let marker else { return false }
        return marker == 61 ? markerCount >= 1 : markerCount >= 3
    }

    private static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == 32 || character == 9
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(Int(character)) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isEscaped(_ location: Int, in source: NSString) -> Bool {
        guard location > 0 else { return false }
        var backslashCount = 0
        var index = location - 1
        while source.character(at: index) == 92 {
            if cancellationCheckpoint(at: index) { return false }
            backslashCount += 1
            guard index > 0 else { break }
            index -= 1
        }
        return backslashCount.isMultiple(of: 2) == false
    }

    private static func exactHTMLClosingTagUpperBound(
        named elementName: String,
        after openingEnd: Int,
        in source: NSString
    ) -> Int? {
        let prefix = "</\(elementName)"
        var searchStart = openingEnd
        while searchStart < source.length {
            guard !Task.isCancelled else { return nil }
            let match = source.range(
                of: prefix,
                options: [.caseInsensitive],
                range: NSRange(location: searchStart, length: source.length - searchStart)
            )
            guard match.location != NSNotFound else { return nil }
            let nameEnd = NSMaxRange(match)
            if nameEnd < source.length {
                let delimiter = source.character(at: nameEnd)
                if delimiter == 32 || delimiter == 9 || delimiter == 10 || delimiter == 12 ||
                    delimiter == 13 || delimiter == 62 {
                    return htmlTagUpperBound(startingAt: match.location, in: source)
                }
            }
            searchStart = max(nameEnd, match.location + 1)
        }
        return nil
    }

    private static func htmlRanges(
        in source: NSString,
        excluding excludedRanges: [NSRange]
    ) -> [NSRange] {
        var result: [NSRange] = []
        var index = 0
        let excludedRanges = excludedRanges.sorted { $0.location < $1.location }
        var excludedIndex = 0

        while index < source.length {
            if cancellationCheckpoint(at: index) { break }
            while excludedIndex < excludedRanges.count,
                  NSMaxRange(excludedRanges[excludedIndex]) <= index {
                excludedIndex += 1
            }
            if excludedIndex < excludedRanges.count,
               NSLocationInRange(index, excludedRanges[excludedIndex]) {
                index = NSMaxRange(excludedRanges[excludedIndex])
                continue
            }
            guard source.character(at: index) == 60 else {
                index += 1
                continue
            }

            if isHTMLCommentOpening(at: index, in: source) {
                let commentBodyStart = index + 4
                let closing = source.range(
                    of: "-->",
                    options: [],
                    range: NSRange(location: commentBodyStart, length: source.length - commentBodyStart)
                )
                let upperBound = closing.location == NSNotFound ? source.length : NSMaxRange(closing)
                result.append(NSRange(location: index, length: upperBound - index))
                index = upperBound
                continue
            }

            if let opening = protectedHTMLBlockOpening(at: index, in: source) {
                let upperBound = opening.isSelfClosing
                    ? opening.upperBound
                    : exactHTMLClosingTagUpperBound(
                        named: opening.elementName,
                        after: opening.upperBound,
                        in: source
                    ) ?? source.length
                result.append(NSRange(location: index, length: upperBound - index))
                index = upperBound
                continue
            }

            guard let upperBound = htmlTagUpperBound(startingAt: index, in: source) else {
                index += 1
                continue
            }
            result.append(NSRange(location: index, length: upperBound - index))
            index = upperBound
        }
        return result
    }

    private static func protectedHTMLBlockOpening(
        at start: Int,
        in source: NSString
    ) -> (elementName: String, upperBound: Int, isSelfClosing: Bool)? {
        var nameEnd = start + 1
        guard nameEnd < source.length, isASCIILetter(source.character(at: nameEnd)) else {
            return nil
        }
        while nameEnd < source.length, isHTMLNameCharacter(source.character(at: nameEnd)) {
            nameEnd += 1
        }
        let elementName = source.substring(
            with: NSRange(location: start + 1, length: nameEnd - start - 1)
        ).lowercased()
        guard elementName == "pre" || elementName == "code" ||
                elementName == "script" || elementName == "style",
              nameEnd < source.length
        else { return nil }
        let delimiter = source.character(at: nameEnd)
        guard delimiter == 32 || delimiter == 9 || delimiter == 10 || delimiter == 12 ||
                delimiter == 13 || delimiter == 47 || delimiter == 62,
              let upperBound = htmlTagUpperBound(startingAt: start, in: source)
        else { return nil }
        var characterBeforeClose = upperBound - 2
        while characterBeforeClose > start,
              isHorizontalWhitespace(source.character(at: characterBeforeClose)) {
            characterBeforeClose -= 1
        }
        return (
            elementName,
            upperBound,
            source.character(at: characterBeforeClose) == 47
        )
    }

    private static func isHTMLCommentOpening(at location: Int, in source: NSString) -> Bool {
        guard location + 4 <= source.length else { return false }
        return source.character(at: location + 1) == 33 &&
            source.character(at: location + 2) == 45 &&
            source.character(at: location + 3) == 45
    }

    private static func htmlTagUpperBound(startingAt start: Int, in source: NSString) -> Int? {
        var index = start + 1
        guard index < source.length else { return nil }

        if source.character(at: index) == 47 {
            index += 1
            guard index < source.length else { return nil }
        }

        let first = source.character(at: index)
        if first == 33 || first == 63 {
            index += 1
        } else {
            guard isASCIILetter(first) else { return nil }
            index += 1
            while index < source.length, isHTMLNameCharacter(source.character(at: index)) {
                if cancellationCheckpoint(at: index) { return nil }
                index += 1
            }
            if index < source.length {
                let delimiter = source.character(at: index)
                guard delimiter == 32 || delimiter == 9 || delimiter == 10 || delimiter == 12 ||
                        delimiter == 13 || delimiter == 47 || delimiter == 62
                else { return nil }
            }
        }

        var quote: unichar?
        while index < source.length {
            if cancellationCheckpoint(at: index) { return nil }
            let character = source.character(at: index)
            if let currentQuote = quote {
                if character == currentQuote {
                    quote = nil
                }
            } else if character == 34 || character == 39 {
                quote = character
            } else if character == 62 {
                return index + 1
            }
            index += 1
        }
        return source.length
    }

    private static func isASCIILetter(_ character: unichar) -> Bool {
        (character >= 65 && character <= 90) || (character >= 97 && character <= 122)
    }

    private static func isHTMLNameCharacter(_ character: unichar) -> Bool {
        isASCIILetter(character) || (character >= 48 && character <= 57) ||
            character == 45 || character == 58
    }

    private static func merged(_ ranges: [NSRange], documentLength: Int) -> [NSRange] {
        let sorted = ranges.compactMap { bounded($0, documentLength: documentLength) }.sorted {
            if $0.location == $1.location {
                return $0.length < $1.length
            }
            return $0.location < $1.location
        }
        guard var current = sorted.first else { return [] }

        var result: [NSRange] = []
        for (index, range) in sorted.dropFirst().enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return [] }
            if range.location <= NSMaxRange(current) {
                current.length = max(NSMaxRange(current), NSMaxRange(range)) - current.location
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
    }

    private static func cancellationCheckpoint(at offset: Int) -> Bool {
        (offset & 255) == 0 && Task.isCancelled
    }

    private static func bounded(_ range: NSRange, documentLength: Int) -> NSRange? {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length > 0,
              range.location < documentLength
        else { return nil }
        return NSRange(
            location: range.location,
            length: min(range.length, documentLength - range.location)
        )
    }
}
