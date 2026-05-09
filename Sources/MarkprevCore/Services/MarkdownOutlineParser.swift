import Foundation

public struct MarkdownOutlineParser: Sendable {
    private struct Fence {
        let marker: Character
        let length: Int
    }

    public init() {}

    public func parse(_ markdown: String) -> [MarkdownOutlineItem] {
        var items: [MarkdownOutlineItem] = []
        var openFence: Fence?
        var lineNumber = 0

        markdown.enumerateLines { line, stop in
            _ = stop
            lineNumber += 1

            if let fence = Self.fence(in: line) {
                if let currentFence = openFence,
                   fence.marker == currentFence.marker,
                   fence.length >= currentFence.length {
                    openFence = nil
                } else if openFence == nil {
                    openFence = fence
                }
                return
            }

            guard openFence == nil, let heading = Self.heading(in: line) else {
                return
            }

            items.append(MarkdownOutlineItem(
                id: "\(lineNumber)-\(heading.level)-\(heading.title)",
                title: heading.title.isEmpty ? "Untitled heading" : heading.title,
                level: heading.level,
                location: MarkdownSourceLocation(line: lineNumber, offset: 0)
            ))
        }

        return items
    }

    private static func heading(in line: String) -> (level: Int, title: String)? {
        let leadingSpaces = line.prefix { $0 == " " }.count
        guard leadingSpaces <= 3 else { return nil }

        let trimmedStart = line.dropFirst(leadingSpaces)
        guard trimmedStart.first == "#" else { return nil }

        let level = trimmedStart.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }

        let afterHashes = trimmedStart.dropFirst(level)
        if let first = afterHashes.first, first != " " && first != "\t" {
            return nil
        }

        let title = stripClosingSequence(from: afterHashes.trimmingCharacters(in: .whitespacesAndNewlines))

        return (level, title)
    }

    private static func stripClosingSequence(from title: String) -> String {
        let hashCount = title.reversed().prefix { $0 == "#" }.count
        guard hashCount > 0 else { return title }

        let closingStart = title.index(title.endIndex, offsetBy: -hashCount)
        guard closingStart > title.startIndex else {
            return ""
        }

        let beforeClosing = title.index(before: closingStart)
        guard title[beforeClosing] == " " || title[beforeClosing] == "\t" else {
            return title
        }

        return title[..<closingStart].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fence(in line: String) -> Fence? {
        let leadingSpaces = line.prefix { $0 == " " }.count
        guard leadingSpaces <= 3 else { return nil }

        let trimmedStart = line.dropFirst(leadingSpaces)
        guard let first = trimmedStart.first, first == "`" || first == "~" else {
            return nil
        }

        let count = trimmedStart.prefix { $0 == first }.count
        return count >= 3 ? Fence(marker: first, length: count) : nil
    }
}
