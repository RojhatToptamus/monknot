import Foundation

public struct MarkdownSourceRange: Equatable, Hashable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var upperBound: Int {
        location + length
    }

    public var nsRange: NSRange {
        NSRange(location: location, length: length)
    }

    public func contains(utf16Offset: Int) -> Bool {
        utf16Offset >= location && utf16Offset < upperBound
    }
}

public enum MarkdownWorkspaceLinkKind: String, Equatable, Hashable, Sendable {
    case markdown
    case wikilink
    case referenceUsage
    case image
    case referenceDefinition
}

public struct MarkdownWorkspaceLink: Equatable, Hashable, Sendable {
    public let kind: MarkdownWorkspaceLinkKind
    public let destination: String
    public let label: String
    public let sourceRange: MarkdownSourceRange
    public let destinationRange: MarkdownSourceRange

    public var destinationComponents: MarkdownLinkDestinationComponents {
        MarkdownLinkDestinationComponents(destination)
    }

    public init(
        kind: MarkdownWorkspaceLinkKind,
        destination: String,
        label: String,
        sourceRange: MarkdownSourceRange,
        destinationRange: MarkdownSourceRange
    ) {
        self.kind = kind
        self.destination = destination
        self.label = label
        self.sourceRange = sourceRange
        self.destinationRange = destinationRange
    }
}

public struct MarkdownLinkDestinationComponents: Equatable, Hashable, Sendable {
    public let path: String
    public let suffix: String
    public let query: String?
    public let fragment: String?

    public init(_ destination: String) {
        let queryIndex = destination.firstIndex(of: "?")
        let fragmentIndex = destination.firstIndex(of: "#")
        let suffixStart = [queryIndex, fragmentIndex].compactMap { $0 }.min()
        if let suffixStart {
            path = String(destination[..<suffixStart])
            suffix = String(destination[suffixStart...])
        } else {
            path = destination
            suffix = ""
        }

        let effectiveQueryIndex = queryIndex.flatMap { index in
            fragmentIndex.map { index < $0 } ?? true ? index : nil
        }
        if let queryIndex = effectiveQueryIndex {
            let valueStart = destination.index(after: queryIndex)
            let valueEnd = fragmentIndex.flatMap { $0 > queryIndex ? $0 : nil } ?? destination.endIndex
            query = String(destination[valueStart..<valueEnd])
        } else {
            query = nil
        }
        if let fragmentIndex {
            fragment = String(destination[destination.index(after: fragmentIndex)...])
        } else {
            fragment = nil
        }
    }

    public func replacingPath(with replacement: String) -> String {
        replacement + suffix
    }
}

public struct MarkdownWorkspaceLinkParser: Sendable {
    private static let markdownExpression = try! NSRegularExpression(
        pattern: #"(?<!!)\[([^\]\r\n]+)\]\(\s*(<[^>\r\n]+>|[^)\s\r\n]+)(?:\s+(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|\([^\)\r\n]*\)))?\s*\)"#
    )
    private static let imageExpression = try! NSRegularExpression(
        pattern: #"!\[([^\]\r\n]*)\]\(\s*(<[^>\r\n]+>|[^)\s\r\n]+)(?:\s+(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|\([^\)\r\n]*\)))?\s*\)"#
    )
    private static let wikilinkExpression = try! NSRegularExpression(
        pattern: #"(?<!!)\[\[([^\]\r\n]+)\]\]"#
    )
    private static let referenceDefinitionExpression = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}\[([^\]\r\n]+)\]:[ \t]*(<[^>\r\n]+>|[^\s\r\n]+)(?:[ \t]+(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|\([^\)\r\n]*\)))?[ \t]*$"#
    )
    private static let referenceUsageExpression = try! NSRegularExpression(
        pattern: #"(?<!!)\[([^\]\r\n]+)\]\[([^\]\r\n]*)\]"#
    )
    private static let inlineCodeExpression = try! NSRegularExpression(
        pattern: #"`+[^`\r\n]*`+"#
    )

    public init() {}

    public func links(in markdown: String) -> [MarkdownWorkspaceLink] {
        let source = markdown as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let fencedRanges = Self.fencedCodeRanges(in: source)
        let inlineCodeRanges = Self.inlineCodeExpression.matches(in: markdown, range: fullRange).map(\.range)
        let excludedRanges = fencedRanges + inlineCodeRanges

        var links: [MarkdownWorkspaceLink] = []
        Self.wikilinkExpression.enumerateMatches(in: markdown, range: fullRange) { match, _, _ in
            guard let match, !Self.isExcluded(match.range.location, by: excludedRanges) else { return }
            let contentRange = match.range(at: 1)
            guard contentRange.location != NSNotFound else { return }

            let content = source.substring(with: contentRange)
            let targetAndLabel = Self.wikilinkTargetAndLabel(in: content, contentRange: contentRange)
            guard !targetAndLabel.target.isEmpty else { return }
            links.append(MarkdownWorkspaceLink(
                kind: .wikilink,
                destination: targetAndLabel.target,
                label: targetAndLabel.label,
                sourceRange: MarkdownSourceRange(match.range),
                destinationRange: MarkdownSourceRange(targetAndLabel.targetRange)
            ))
        }

        Self.markdownExpression.enumerateMatches(in: markdown, range: fullRange) { match, _, _ in
            guard let match, !Self.isExcluded(match.range.location, by: excludedRanges) else { return }
            let labelRange = match.range(at: 1)
            var destinationRange = match.range(at: 2)
            guard labelRange.location != NSNotFound, destinationRange.location != NSNotFound else { return }

            var destination = source.substring(with: destinationRange)
            if destination.hasPrefix("<"), destination.hasSuffix(">"), destinationRange.length >= 2 {
                destination = String(destination.dropFirst().dropLast())
                destinationRange = NSRange(location: destinationRange.location + 1, length: destinationRange.length - 2)
            }
            guard !destination.isEmpty else { return }

            links.append(MarkdownWorkspaceLink(
                kind: .markdown,
                destination: destination,
                label: source.substring(with: labelRange),
                sourceRange: MarkdownSourceRange(match.range),
                destinationRange: MarkdownSourceRange(destinationRange)
            ))
        }

        Self.imageExpression.enumerateMatches(in: markdown, range: fullRange) { match, _, _ in
            guard let match, !Self.isExcluded(match.range.location, by: excludedRanges) else { return }
            let labelRange = match.range(at: 1)
            var destinationRange = match.range(at: 2)
            guard labelRange.location != NSNotFound, destinationRange.location != NSNotFound else { return }
            var destination = source.substring(with: destinationRange)
            if destination.hasPrefix("<"), destination.hasSuffix(">"), destinationRange.length >= 2 {
                destination = String(destination.dropFirst().dropLast())
                destinationRange = NSRange(location: destinationRange.location + 1, length: destinationRange.length - 2)
            }
            guard !destination.isEmpty else { return }
            links.append(MarkdownWorkspaceLink(
                kind: .image,
                destination: destination,
                label: source.substring(with: labelRange),
                sourceRange: MarkdownSourceRange(match.range),
                destinationRange: MarkdownSourceRange(destinationRange)
            ))
        }

        Self.referenceDefinitionExpression.enumerateMatches(in: markdown, range: fullRange) { match, _, _ in
            guard let match, !Self.isExcluded(match.range.location, by: excludedRanges) else { return }
            let labelRange = match.range(at: 1)
            var destinationRange = match.range(at: 2)
            guard labelRange.location != NSNotFound, destinationRange.location != NSNotFound else { return }
            let label = source.substring(with: labelRange)
            guard !label.hasPrefix("^") else { return }
            var destination = source.substring(with: destinationRange)
            if destination.hasPrefix("<"), destination.hasSuffix(">"), destinationRange.length >= 2 {
                destination = String(destination.dropFirst().dropLast())
                destinationRange = NSRange(location: destinationRange.location + 1, length: destinationRange.length - 2)
            }
            guard !destination.isEmpty else { return }
            links.append(MarkdownWorkspaceLink(
                kind: .referenceDefinition,
                destination: destination,
                label: label,
                sourceRange: MarkdownSourceRange(match.range),
                destinationRange: MarkdownSourceRange(destinationRange)
            ))
        }

        var definitions: [String: MarkdownWorkspaceLink] = [:]
        for link in links where link.kind == .referenceDefinition {
            let key = Self.normalizedReferenceLabel(link.label)
            if definitions[key] == nil {
                definitions[key] = link
            }
        }
        Self.referenceUsageExpression.enumerateMatches(in: markdown, range: fullRange) { match, _, _ in
            guard let match, !Self.isExcluded(match.range.location, by: excludedRanges) else { return }
            let labelRange = match.range(at: 1)
            let identifierRange = match.range(at: 2)
            guard labelRange.location != NSNotFound,
                  identifierRange.location != NSNotFound
            else { return }
            let label = source.substring(with: labelRange)
            let identifier = identifierRange.length == 0
                ? label
                : source.substring(with: identifierRange)
            guard let definition = definitions[Self.normalizedReferenceLabel(identifier)] else { return }
            links.append(MarkdownWorkspaceLink(
                kind: .referenceUsage,
                destination: definition.destination,
                label: label,
                sourceRange: MarkdownSourceRange(match.range),
                destinationRange: MarkdownSourceRange(
                    identifierRange.length == 0 ? labelRange : identifierRange
                )
            ))
        }

        return links.sorted {
            if $0.sourceRange.location == $1.sourceRange.location {
                return $0.sourceRange.length < $1.sourceRange.length
            }
            return $0.sourceRange.location < $1.sourceRange.location
        }
    }

    public func link(atUTF16Offset offset: Int, in markdown: String) -> MarkdownWorkspaceLink? {
        guard offset >= 0 else { return nil }
        return links(in: markdown).first { $0.sourceRange.contains(utf16Offset: offset) }
    }

    private static func wikilinkTargetAndLabel(
        in content: String,
        contentRange: NSRange
    ) -> (target: String, label: String, targetRange: NSRange) {
        let contentString = content as NSString
        let separatorRange = contentString.range(of: "|")
        let untrimmedTargetRange = separatorRange.location == NSNotFound
            ? NSRange(location: 0, length: contentString.length)
            : NSRange(location: 0, length: separatorRange.location)
        let targetRange = trimmedRange(untrimmedTargetRange, in: contentString)
        let target = contentString.substring(with: targetRange)

        let label: String
        if separatorRange.location == NSNotFound {
            label = target
        } else {
            let untrimmedLabelRange = NSRange(
                location: NSMaxRange(separatorRange),
                length: contentString.length - NSMaxRange(separatorRange)
            )
            let trimmedLabelRange = trimmedRange(untrimmedLabelRange, in: contentString)
            let alias = contentString.substring(with: trimmedLabelRange)
            label = alias.isEmpty ? target : alias
        }

        return (
            target,
            label,
            NSRange(location: contentRange.location + targetRange.location, length: targetRange.length)
        )
    }

    private static func trimmedRange(_ range: NSRange, in source: NSString) -> NSRange {
        var lowerBound = range.location
        var upperBound = NSMaxRange(range)
        let whitespace = CharacterSet.whitespacesAndNewlines

        while lowerBound < upperBound,
              let scalar = UnicodeScalar(source.character(at: lowerBound)),
              whitespace.contains(scalar) {
            lowerBound += 1
        }
        while upperBound > lowerBound,
              let scalar = UnicodeScalar(source.character(at: upperBound - 1)),
              whitespace.contains(scalar) {
            upperBound -= 1
        }
        return NSRange(location: lowerBound, length: upperBound - lowerBound)
    }

    private static func isExcluded(_ location: Int, by excludedRanges: [NSRange]) -> Bool {
        excludedRanges.contains { NSLocationInRange(location, $0) }
    }

    private static func normalizedReferenceLabel(_ label: String) -> String {
        label.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func fencedCodeRanges(in source: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var lineLocation = 0
        var openFence: (marker: unichar, length: Int, start: Int)?

        while lineLocation < source.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: lineLocation, length: 0)
            )
            let line = source.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart)) as NSString
            if let fence = fence(in: line) {
                if let current = openFence,
                   current.marker == fence.marker,
                   fence.length >= current.length {
                    ranges.append(NSRange(location: current.start, length: lineEnd - current.start))
                    openFence = nil
                } else if openFence == nil {
                    openFence = (fence.marker, fence.length, lineStart)
                }
            }
            guard lineEnd > lineLocation else { break }
            lineLocation = lineEnd
        }

        if let openFence {
            ranges.append(NSRange(location: openFence.start, length: source.length - openFence.start))
        }
        return ranges
    }

    private static func fence(in line: NSString) -> (marker: unichar, length: Int)? {
        var index = 0
        while index < line.length, index < 4, line.character(at: index) == 32 {
            index += 1
        }
        guard index <= 3, index < line.length else { return nil }
        let marker = line.character(at: index)
        guard marker == 96 || marker == 126 else { return nil }
        var length = 0
        while index + length < line.length, line.character(at: index + length) == marker {
            length += 1
        }
        return length >= 3 ? (marker, length) : nil
    }
}

public enum MarkdownWorkspaceLinkResolution: Equatable, Sendable {
    case document(documentID: String, fragment: String?)
    case external(URL)
    case ambiguous(documentIDs: [String])
    case missing
    case invalid
}

public struct MarkdownWorkspaceLinkResolver: Sendable {
    public init() {}

    public func resolve(
        _ link: MarkdownWorkspaceLink,
        sourceDocument: WorkspaceDocument,
        workspaceRootURL: URL,
        documents: [WorkspaceDocument]
    ) -> MarkdownWorkspaceLinkResolution {
        guard link.kind == .markdown || link.kind == .wikilink || link.kind == .referenceUsage else {
            return .invalid
        }
        let rawDestination = link.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawDestination.isEmpty, !rawDestination.contains("\0") else { return .invalid }

        if let scheme = Self.explicitScheme(in: rawDestination) {
            switch scheme {
            case "http", "https", "mailto":
                guard let url = URL(string: rawDestination) else { return .invalid }
                return .external(url)
            case "file":
                guard let url = URL(string: rawDestination), url.isFileURL else { return .invalid }
                let fragment = Self.fragment(in: rawDestination)
                return resolveFileURL(
                    url,
                    fragment: fragment,
                    workspaceRootURL: workspaceRootURL,
                    documents: documents
                )
            default:
                return .invalid
            }
        }

        let components = MarkdownLinkDestinationComponents(rawDestination)
        if components.path.isEmpty {
            guard let fragment = components.fragment.flatMap(Self.decodePercentEscapes) else { return .invalid }
            return .document(
                documentID: sourceDocument.id,
                fragment: MarkdownHeadingFragment.normalized(fragment)
            )
        }

        guard let decodedPath = Self.decodePercentEscapes(components.path), !decodedPath.isEmpty else {
            return .invalid
        }
        let decodedFragment = components.fragment.flatMap(Self.decodePercentEscapes)
        if components.fragment != nil, decodedFragment == nil { return .invalid }
        let fragment = decodedFragment.map(MarkdownHeadingFragment.normalized)
        let root = Self.canonicalURL(workspaceRootURL)
        let sourceURL = Self.canonicalURL(sourceDocument.url)
        guard Self.isContained(sourceURL, in: root) else { return .invalid }

        var candidates: [URL] = []
        if decodedPath.hasPrefix("/") {
            candidates.append(root.appendingPathComponent(String(decodedPath.drop(while: { $0 == "/" }))))
        } else {
            candidates.append(sourceURL.deletingLastPathComponent().appendingPathComponent(decodedPath))
            candidates.append(root.appendingPathComponent(decodedPath))
        }
        if (decodedPath as NSString).pathExtension.isEmpty {
            for fileExtension in ["md", "markdown", "mdown", "mkd"] {
                let suffix = ".\(fileExtension)"
                if decodedPath.hasPrefix("/") {
                    candidates.append(root.appendingPathComponent(String(decodedPath.drop(while: { $0 == "/" })) + suffix))
                } else {
                    candidates.append(sourceURL.deletingLastPathComponent().appendingPathComponent(decodedPath + suffix))
                    candidates.append(root.appendingPathComponent(decodedPath + suffix))
                }
            }
        }

        var documentMap: [String: WorkspaceDocument] = [:]
        for document in documents {
            let path = Self.canonicalURL(document.url).path
            if documentMap[path] == nil {
                documentMap[path] = document
            }
        }
        for candidate in Self.uniqueCanonicalURLs(candidates) {
            guard Self.isContained(candidate, in: root) else { return .invalid }
            if let document = documentMap[candidate.path] {
                return .document(documentID: document.id, fragment: fragment)
            }
        }

        guard link.kind == .wikilink, !decodedPath.contains("/") else { return .missing }
        let foldedTarget = Self.folded((decodedPath as NSString).deletingPathExtension)
        let basenameMatches = documents.filter { document in
            guard document.kind == .markdown else { return false }
            let name = (document.url.deletingPathExtension().lastPathComponent)
            return Self.folded(name) == foldedTarget
        }
        if basenameMatches.count == 1, let document = basenameMatches.first {
            return .document(documentID: document.id, fragment: fragment)
        }
        if basenameMatches.count > 1 {
            return .ambiguous(documentIDs: basenameMatches.map(\.id).sorted())
        }
        return .missing
    }

    private func resolveFileURL(
        _ url: URL,
        fragment: String?,
        workspaceRootURL: URL,
        documents: [WorkspaceDocument]
    ) -> MarkdownWorkspaceLinkResolution {
        let root = Self.canonicalURL(workspaceRootURL)
        let candidate = Self.canonicalURL(url)
        guard Self.isContained(candidate, in: root) else { return .invalid }
        guard let document = documents.first(where: { Self.canonicalURL($0.url).path == candidate.path }) else {
            return .missing
        }
        return .document(
            documentID: document.id,
            fragment: fragment.map(MarkdownHeadingFragment.normalized)
        )
    }

    private static func explicitScheme(in destination: String) -> String? {
        guard let separator = destination.firstIndex(of: ":") else { return nil }
        let scheme = String(destination[..<separator])
        guard scheme.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return scheme.lowercased()
    }

    private static func pathAndFragment(in destination: String) -> (path: String, fragment: String?) {
        guard let separator = destination.firstIndex(of: "#") else {
            return (destination, nil)
        }
        let path = String(destination[..<separator])
        let fragmentStart = destination.index(after: separator)
        let rawFragment = String(destination[fragmentStart...])
        return (path, decodePercentEscapes(rawFragment))
    }

    private static func fragment(in destination: String) -> String? {
        pathAndFragment(in: destination).fragment
    }

    private static func decodePercentEscapes(_ value: String) -> String? {
        guard value.contains("%") else { return value }
        return value.removingPercentEncoding
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func uniqueCanonicalURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.compactMap { url in
            let canonical = canonicalURL(url)
            guard seen.insert(canonical.path).inserted else { return nil }
            return canonical
        }
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

public enum MarkdownHeadingFragment {
    public static func normalized(_ value: String) -> String {
        var result = value
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result = replacing(#"<[^>]*>"#, in: result, with: "")
        result = replacing(#"[^a-z0-9\s-]"#, in: result, with: "")
        result = replacing(#"\s+"#, in: result, with: "-")
        result = replacing(#"-+"#, in: result, with: "-")
        return result.isEmpty ? "section" : result
    }

    public static func sourceLocation(for fragment: String, in markdown: String) -> MarkdownSourceLocation? {
        let target = normalized(fragment)
        var lineNumber = 0
        var openFence: (marker: Character, length: Int)?
        var result: MarkdownSourceLocation?

        markdown.enumerateLines { line, stop in
            lineNumber += 1
            if let fence = fence(in: line) {
                if let current = openFence,
                   current.marker == fence.marker,
                   fence.length >= current.length {
                    openFence = nil
                } else if openFence == nil {
                    openFence = fence
                }
                return
            }
            guard openFence == nil, let title = headingTitle(in: line) else { return }
            if normalized(stripInline(from: title)) == target {
                result = MarkdownSourceLocation(line: lineNumber, offset: 0)
                stop = true
            }
        }
        return result
    }

    private static func headingTitle(in line: String) -> String? {
        let leadingSpaces = line.prefix { $0 == " " }.count
        guard leadingSpaces <= 3 else { return nil }
        let trimmedStart = line.dropFirst(leadingSpaces)
        let level = trimmedStart.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let remainder = trimmedStart.dropFirst(level)
        guard remainder.first == " " || remainder.first == "\t" else { return nil }
        var title = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(
            of: #"[ \t]+#+[ \t]*$"#,
            with: "",
            options: .regularExpression
        )
        return title
    }

    private static func stripInline(from title: String) -> String {
        var result = replacing(#"`([^`]+)`"#, in: title, with: "$1")
        result = replacing(#"!\[([^\]]*)\]\([^)]+\)"#, in: result, with: "$1")
        result = replacing(#"\[([^\]]+)\]\([^)]+\)"#, in: result, with: "$1")
        return replacing(#"[*_~#]"#, in: result, with: "")
    }

    private static func fence(in line: String) -> (marker: Character, length: Int)? {
        let leadingSpaces = line.prefix { $0 == " " }.count
        guard leadingSpaces <= 3 else { return nil }
        let remainder = line.dropFirst(leadingSpaces)
        guard let marker = remainder.first, marker == "`" || marker == "~" else { return nil }
        let length = remainder.prefix { $0 == marker }.count
        return length >= 3 ? (marker, length) : nil
    }

    private static func replacing(_ pattern: String, in value: String, with template: String) -> String {
        value.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}

public struct MarkdownTaskSourceReplacement: Equatable, Sendable {
    public let range: MarkdownSourceRange
    public let expectedText: String
    public let replacementText: String

    public init(range: MarkdownSourceRange, expectedText: String, replacementText: String) {
        self.range = range
        self.expectedText = expectedText
        self.replacementText = replacementText
    }
}

public enum MarkdownTaskSourceMutation {
    private static let markerExpression = try! NSRegularExpression(
        pattern: #"^\s*(?:[-+*]|\d+[.)])\s+\[([ xX])\]"#
    )

    public static func replacement(
        in markdown: String,
        sourceLine: Int,
        expectedChecked: Bool,
        desiredChecked: Bool
    ) -> MarkdownTaskSourceReplacement? {
        guard sourceLine > 0 else { return nil }
        let source = markdown as NSString
        guard let lineRange = lineRange(sourceLine, in: source) else { return nil }
        var contentsEnd = NSMaxRange(lineRange)
        while contentsEnd > lineRange.location {
            let character = source.character(at: contentsEnd - 1)
            guard character == 10 || character == 13 else { break }
            contentsEnd -= 1
        }
        let contentsRange = NSRange(location: lineRange.location, length: contentsEnd - lineRange.location)
        let line = source.substring(with: contentsRange)
        let localRange = NSRange(location: 0, length: (line as NSString).length)
        guard let match = markerExpression.firstMatch(in: line, range: localRange) else { return nil }
        let markerRange = match.range(at: 1)
        guard markerRange.location != NSNotFound else { return nil }
        let expectedText = (line as NSString).substring(with: markerRange)
        let currentlyChecked = expectedText == "x" || expectedText == "X"
        guard currentlyChecked == expectedChecked else { return nil }

        return MarkdownTaskSourceReplacement(
            range: MarkdownSourceRange(
                location: contentsRange.location + markerRange.location,
                length: markerRange.length
            ),
            expectedText: expectedText,
            replacementText: desiredChecked ? "x" : " "
        )
    }

    private static func lineRange(_ lineNumber: Int, in source: NSString) -> NSRange? {
        var currentLine = 1
        var location = 0
        while currentLine < lineNumber, location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            let next = NSMaxRange(range)
            guard next > location else { return nil }
            location = next
            currentLine += 1
        }
        guard currentLine == lineNumber, location <= source.length else { return nil }
        if location == source.length, lineNumber > 1, source.length > 0 {
            let last = source.character(at: source.length - 1)
            guard last == 10 || last == 13 else { return nil }
        }
        return source.lineRange(for: NSRange(location: location, length: 0))
    }
}

private extension MarkdownSourceRange {
    init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }
}
