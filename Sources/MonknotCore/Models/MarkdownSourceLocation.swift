import Foundation

public struct MarkdownSourceLocation: Equatable, Sendable {
    public let line: Int
    public let offset: Int

    public init(line: Int, offset: Int) {
        self.line = line
        self.offset = offset
    }
}

public enum MarkdownSourceLocationInputError: Error, Equatable, Sendable {
    case invalidFormat
    case lineOutOfRange(maximum: Int)
    case columnOutOfRange(maximum: Int)
}

public enum MarkdownSourceLocationInputParser {
    /// Parses a one-based `line` or `line:column` position. Columns count
    /// user-perceived characters and are converted to the UTF-16 offsets used
    /// by AppKit and `MarkdownSourceLocation`.
    public static func parse(
        _ input: String,
        in text: String
    ) -> Result<MarkdownSourceLocation, MarkdownSourceLocationInputError> {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmedInput.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count),
              let line = Int(components[0]),
              line > 0
        else {
            return .failure(.invalidFormat)
        }

        let requestedColumn: Int
        if components.count == 2 {
            guard let column = Int(components[1]), column > 0 else {
                return .failure(.invalidFormat)
            }
            requestedColumn = column
        } else {
            requestedColumn = 1
        }

        let source = text as NSString
        var currentLine = 1
        var lineStart = 0
        while currentLine < line, lineStart < source.length {
            let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
            let nextLineStart = NSMaxRange(lineRange)
            guard nextLineStart > lineStart else { break }
            lineStart = nextLineStart
            currentLine += 1
        }

        let hasTrailingEmptyLine = source.length > 0
            && [0x0A, 0x0D].contains(source.character(at: source.length - 1))
        guard currentLine == line,
              line == 1 || lineStart < source.length || hasTrailingEmptyLine
        else {
            return .failure(.lineOutOfRange(maximum: lineCount(in: source)))
        }

        let fullLineRange = source.lineRange(
            for: NSRange(location: min(lineStart, source.length), length: 0)
        )
        var contentEnd = min(NSMaxRange(fullLineRange), source.length)
        while contentEnd > lineStart,
              [0x0A, 0x0D].contains(source.character(at: contentEnd - 1)) {
            contentEnd -= 1
        }

        let lineText = source.substring(
            with: NSRange(location: lineStart, length: contentEnd - lineStart)
        )
        let maximumColumn = lineText.count + 1
        guard requestedColumn <= maximumColumn else {
            return .failure(.columnOutOfRange(maximum: maximumColumn))
        }

        let characterIndex = lineText.index(
            lineText.startIndex,
            offsetBy: requestedColumn - 1
        )
        let utf16Offset = lineText[..<characterIndex].utf16.count
        return .success(MarkdownSourceLocation(line: line, offset: utf16Offset))
    }

    private static func lineCount(in source: NSString) -> Int {
        guard source.length > 0 else { return 1 }
        var count = 1
        var lineStart = 0
        while lineStart < source.length {
            let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
            let nextLineStart = NSMaxRange(lineRange)
            guard nextLineStart > lineStart else { break }
            lineStart = nextLineStart
            if lineStart < source.length
                || [0x0A, 0x0D].contains(source.character(at: source.length - 1)) {
                count += 1
            }
        }
        return count
    }
}
