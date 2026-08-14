import Foundation

public enum MarkdownListEditCommand: Equatable, Sendable {
    case newline
    case indent
    case outdent
}

public struct MarkdownListEditPlan: Equatable, Sendable {
    public let replacementRange: NSRange
    public let replacementText: String
    public let selectedRange: NSRange

    public init(
        replacementRange: NSRange,
        replacementText: String,
        selectedRange: NSRange
    ) {
        self.replacementRange = replacementRange
        self.replacementText = replacementText
        self.selectedRange = selectedRange
    }
}

public enum MarkdownListEditPlanner {
    private static let indentation = "  "
    private static let listPattern = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+])([ \t]+)(?:\[([ xX])\](?=$|[ \t])([ \t]*))?|([0-9]+)([.)])([ \t]+))(.*)$"#
    )

    public static func plan(
        _ command: MarkdownListEditCommand,
        in text: String,
        selectedRange: NSRange
    ) -> MarkdownListEditPlan? {
        let textLength = (text as NSString).length
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              selectedRange.location <= textLength,
              NSMaxRange(selectedRange) <= textLength
        else { return nil }

        switch command {
        case .newline:
            return newlinePlan(in: text, selectedRange: selectedRange)
        case .indent, .outdent:
            return indentationPlan(command, in: text, selectedRange: selectedRange)
        }
    }

    private static func newlinePlan(
        in text: String,
        selectedRange: NSRange
    ) -> MarkdownListEditPlan? {
        guard selectedRange.length == 0 else { return nil }
        let source = text as NSString
        let caret = selectedRange.location
        let bounds = lineBounds(containing: caret, in: source)
        guard !containsFencedLine(at: [bounds.start], in: source) else { return nil }

        let line = source.substring(with: NSRange(
            location: bounds.start,
            length: bounds.contentEnd - bounds.start
        ))
        guard let item = listItem(in: line), caret >= bounds.start + item.prefixLength else {
            return nil
        }

        if item.content.trimmingCharacters(in: .whitespaces).isEmpty,
           caret == bounds.contentEnd {
            return MarkdownListEditPlan(
                replacementRange: NSRange(
                    location: bounds.start,
                    length: bounds.contentEnd - bounds.start
                ),
                replacementText: item.indentation,
                selectedRange: NSRange(
                    location: bounds.start + (item.indentation as NSString).length,
                    length: 0
                )
            )
        }

        let insertion = lineEnding(around: bounds, in: source) + item.continuationPrefix
        return MarkdownListEditPlan(
            replacementRange: selectedRange,
            replacementText: insertion,
            selectedRange: NSRange(
                location: caret + (insertion as NSString).length,
                length: 0
            )
        )
    }

    private static func indentationPlan(
        _ command: MarkdownListEditCommand,
        in text: String,
        selectedRange: NSRange
    ) -> MarkdownListEditPlan? {
        let source = text as NSString
        let editBounds = selectedLineBounds(for: selectedRange, in: source)
        let lines = physicalLines(from: editBounds.start, through: editBounds.contentEnd, in: source)
        guard !lines.isEmpty,
              !containsFencedLine(at: Set(lines.map(\.start)), in: source)
        else { return nil }

        var mutations: [Mutation] = []
        for line in lines {
            let content = source.substring(with: NSRange(
                location: line.start,
                length: line.contentEnd - line.start
            ))
            if content.isEmpty { continue }
            guard let item = listItem(in: content) else { return nil }

            switch command {
            case .indent:
                mutations.append(Mutation(
                    range: NSRange(location: line.start - editBounds.start, length: 0),
                    replacement: indentation
                ))
            case .outdent:
                let removableLength = removableIndentationLength(item.indentation)
                if removableLength > 0 {
                    mutations.append(Mutation(
                        range: NSRange(
                            location: line.start - editBounds.start,
                            length: removableLength
                        ),
                        replacement: ""
                    ))
                }
            case .newline:
                break
            }
        }
        guard !mutations.isEmpty else { return nil }

        let replacementRange = NSRange(
            location: editBounds.start,
            length: editBounds.nextStart - editBounds.start
        )
        let original = source.substring(with: replacementRange) as NSString
        let replacement = original.mutableCopy() as! NSMutableString
        for mutation in mutations.reversed() {
            replacement.replaceCharacters(in: mutation.range, with: mutation.replacement)
        }

        let selectionStart = mapOffset(
            selectedRange.location - replacementRange.location,
            through: mutations
        ) + replacementRange.location
        let selectionEnd = mapOffset(
            NSMaxRange(selectedRange) - replacementRange.location,
            through: mutations
        ) + replacementRange.location
        return MarkdownListEditPlan(
            replacementRange: replacementRange,
            replacementText: replacement as String,
            selectedRange: NSRange(
                location: selectionStart,
                length: max(0, selectionEnd - selectionStart)
            )
        )
    }

    private static func listItem(in line: String) -> ListItem? {
        let source = line as NSString
        let match = listPattern.firstMatch(
            in: line,
            range: NSRange(location: 0, length: source.length)
        )
        guard let match else { return nil }

        let indentation = substring(match.range(at: 1), in: source)
        let content = substring(match.range(at: 9), in: source)
        let prefixLength = match.range(at: 9).location
        if match.range(at: 6).location != NSNotFound {
            let number = substring(match.range(at: 6), in: source)
            let delimiter = substring(match.range(at: 7), in: source)
            let spacing = substring(match.range(at: 8), in: source)
            return ListItem(
                indentation: indentation,
                continuationPrefix: indentation + increment(number) + delimiter + spacing,
                prefixLength: prefixLength,
                content: content
            )
        }

        let bullet = substring(match.range(at: 2), in: source)
        let spacing = substring(match.range(at: 3), in: source)
        let continuationPrefix: String
        if match.range(at: 4).location != NSNotFound {
            let taskSpacing = substring(match.range(at: 5), in: source)
            continuationPrefix = indentation
                + bullet
                + spacing
                + "[ ]"
                + (taskSpacing.isEmpty ? " " : taskSpacing)
        } else {
            continuationPrefix = indentation + bullet + spacing
        }
        return ListItem(
            indentation: indentation,
            continuationPrefix: continuationPrefix,
            prefixLength: prefixLength,
            content: content
        )
    }

    private static func increment(_ decimal: String) -> String {
        guard let value = UInt64(decimal), value < UInt64.max else { return decimal }
        return String(value + 1)
    }

    private static func removableIndentationLength(_ indentation: String) -> Int {
        let source = indentation as NSString
        guard source.length > 0 else { return 0 }
        if source.character(at: 0) == 9 { return 1 }
        var count = 0
        while count < min(2, source.length), source.character(at: count) == 32 {
            count += 1
        }
        return count
    }

    private static func mapOffset(_ offset: Int, through mutations: [Mutation]) -> Int {
        var mapped = offset
        for mutation in mutations {
            let replacementLength = (mutation.replacement as NSString).length
            let start = mutation.range.location
            let end = NSMaxRange(mutation.range)
            if offset < start { break }
            if mutation.range.length == 0 || offset >= end {
                mapped += replacementLength - mutation.range.length
            } else {
                mapped = start + replacementLength
                break
            }
        }
        return mapped
    }

    private static func selectedLineBounds(
        for selectedRange: NSRange,
        in text: NSString
    ) -> LineBounds {
        let first = lineBounds(containing: selectedRange.location, in: text)
        let lastOffset: Int
        if selectedRange.length > 0 {
            lastOffset = max(selectedRange.location, NSMaxRange(selectedRange) - 1)
        } else {
            lastOffset = selectedRange.location
        }
        let last = lineBounds(containing: lastOffset, in: text)
        return LineBounds(
            start: first.start,
            contentEnd: last.contentEnd,
            nextStart: last.nextStart
        )
    }

    private static func physicalLines(
        from start: Int,
        through contentEnd: Int,
        in text: NSString
    ) -> [LineBounds] {
        var result: [LineBounds] = []
        var offset = start
        repeat {
            let line = lineBounds(containing: offset, in: text)
            result.append(line)
            guard line.nextStart > line.contentEnd,
                  line.nextStart > offset,
                  line.nextStart <= contentEnd
            else { break }
            offset = line.nextStart
        } while offset <= contentEnd
        return result
    }

    private static func lineBounds(containing offset: Int, in text: NSString) -> LineBounds {
        let clamped = min(max(offset, 0), text.length)
        var start = clamped
        while start > 0 {
            let character = text.character(at: start - 1)
            if character == 10 || character == 13 { break }
            start -= 1
        }

        var contentEnd = clamped
        while contentEnd < text.length {
            let character = text.character(at: contentEnd)
            if character == 10 || character == 13 { break }
            contentEnd += 1
        }

        var nextStart = contentEnd
        if nextStart < text.length, text.character(at: nextStart) == 13 {
            nextStart += 1
            if nextStart < text.length, text.character(at: nextStart) == 10 {
                nextStart += 1
            }
        } else if nextStart < text.length, text.character(at: nextStart) == 10 {
            nextStart += 1
        }
        return LineBounds(start: start, contentEnd: contentEnd, nextStart: nextStart)
    }

    private static func lineEnding(around bounds: LineBounds, in text: NSString) -> String {
        if bounds.contentEnd < text.length {
            if text.character(at: bounds.contentEnd) == 13,
               bounds.contentEnd + 1 < text.length,
               text.character(at: bounds.contentEnd + 1) == 10 {
                return "\r\n"
            }
            return String(UnicodeScalar(text.character(at: bounds.contentEnd))!)
        }
        if bounds.start >= 2,
           text.character(at: bounds.start - 2) == 13,
           text.character(at: bounds.start - 1) == 10 {
            return "\r\n"
        }
        if bounds.start > 0, text.character(at: bounds.start - 1) == 13 {
            return "\r"
        }
        return "\n"
    }

    private static func containsFencedLine(
        at lineStarts: Set<Int>,
        in text: NSString
    ) -> Bool {
        guard let lastLineStart = lineStarts.max() else { return false }
        var activeFence: Fence?
        var offset = 0
        while offset <= lastLineStart {
            let bounds = lineBounds(containing: offset, in: text)
            if lineStarts.contains(bounds.start), activeFence != nil {
                return true
            }
            let line = text.substring(with: NSRange(
                location: bounds.start,
                length: bounds.contentEnd - bounds.start
            ))
            if let candidate = fence(in: line) {
                if let currentFence = activeFence {
                    if candidate.character == currentFence.character,
                       candidate.length >= currentFence.length,
                       candidate.hasOnlyTrailingWhitespace {
                        activeFence = nil
                    }
                } else {
                    activeFence = candidate
                }
            }
            guard bounds.nextStart > offset else { break }
            offset = bounds.nextStart
        }
        return false
    }

    private static func fence(in line: String) -> Fence? {
        let source = line as NSString
        var offset = 0
        while offset < source.length, offset < 4, source.character(at: offset) == 32 {
            offset += 1
        }
        guard offset <= 3, offset < source.length else { return nil }
        let character = source.character(at: offset)
        guard character == 96 || character == 126 else { return nil }
        var end = offset
        while end < source.length, source.character(at: end) == character {
            end += 1
        }
        guard end - offset >= 3 else { return nil }
        let trailing = source.substring(from: end)
        return Fence(
            character: character,
            length: end - offset,
            hasOnlyTrailingWhitespace: trailing.trimmingCharacters(in: .whitespaces).isEmpty
        )
    }

    private static func substring(_ range: NSRange, in source: NSString) -> String {
        guard range.location != NSNotFound else { return "" }
        return source.substring(with: range)
    }

    private struct ListItem {
        let indentation: String
        let continuationPrefix: String
        let prefixLength: Int
        let content: String
    }

    private struct LineBounds {
        let start: Int
        let contentEnd: Int
        let nextStart: Int
    }

    private struct Mutation {
        let range: NSRange
        let replacement: String
    }

    private struct Fence {
        let character: unichar
        let length: Int
        let hasOnlyTrailingWhitespace: Bool
    }
}
