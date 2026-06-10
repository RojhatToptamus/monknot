import Foundation

public enum MarkdownScrollSync: Sendable {
    public static func lineNumber(forCharacterIndex index: Int, in text: String) -> Int {
        let nsText = text as NSString
        guard nsText.length > 0 else { return 1 }

        let clampedIndex = max(0, min(index, nsText.length - 1))
        var line = 1
        var lineStart = 0

        while lineStart < clampedIndex {
            let lineRange = nsText.lineRange(for: NSRange(location: lineStart, length: 0))
            let nextLocation = NSMaxRange(lineRange)
            guard nextLocation > lineStart else { break }
            lineStart = nextLocation
            line += 1
        }

        return line
    }

    public static func characterOffset(forLine line: Int, in text: String) -> Int {
        let nsText = text as NSString
        let targetLine = max(1, line)
        var currentLine = 1
        var lineStart = 0

        while currentLine < targetLine, lineStart < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: lineStart, length: 0))
            let nextLocation = NSMaxRange(lineRange)
            guard nextLocation > lineStart else { break }
            lineStart = nextLocation
            currentLine += 1
        }

        return min(lineStart, nsText.length)
    }
}
