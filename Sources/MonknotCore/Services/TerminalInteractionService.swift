import Foundation

public struct TerminalFileReference: Equatable, Sendable {
    public let path: String
    public let line: Int?
    public let column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }
}

public struct ResolvedTerminalFileReference: Equatable, Sendable {
    public let url: URL
    public let line: Int?
    public let column: Int?

    public init(url: URL, line: Int? = nil, column: Int? = nil) {
        self.url = url
        self.line = line
        self.column = column
    }
}

public enum TerminalFileReferenceParser {
    private static let maximumCandidateLength = 4_096
    private static let locationExpression = try! NSRegularExpression(
        pattern: #"^(.*?):(-?[0-9]+)(?::(-?[0-9]+))?$"#
    )
    private static let URLSchemeExpression = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9+.-]*://"#
    )

    public static func parse(_ candidate: String) -> TerminalFileReference? {
        var candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.utf16.count <= maximumCandidateLength else {
            return nil
        }

        candidate = unwrapped(candidate)
        let candidateRange = NSRange(location: 0, length: (candidate as NSString).length)

        let path: String
        let line: Int?
        let column: Int?
        if let match = locationExpression.firstMatch(in: candidate, range: candidateRange) {
            guard let pathRange = Range(match.range(at: 1), in: candidate),
                  let lineRange = Range(match.range(at: 2), in: candidate),
                  let parsedLine = Int(candidate[lineRange]),
                  parsedLine > 0
            else {
                return nil
            }
            path = unwrapped(String(candidate[pathRange]).trimmingCharacters(in: .whitespaces))
            line = parsedLine
            if match.range(at: 3).location != NSNotFound,
               let columnRange = Range(match.range(at: 3), in: candidate) {
                guard let parsedColumn = Int(candidate[columnRange]), parsedColumn > 0 else {
                    return nil
                }
                column = parsedColumn
            } else {
                column = nil
            }
        } else {
            if candidate.range(
                of: #":-?[0-9]+(?::-?[0-9]+)?$"#,
                options: .regularExpression
            ) != nil {
                return nil
            }
            path = unwrapped(candidate)
            line = nil
            column = nil
        }

        guard isSafePath(path) else { return nil }
        return TerminalFileReference(path: path, line: line, column: column)
    }

    private static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return false
        }

        let range = NSRange(location: 0, length: (path as NSString).length)
        return URLSchemeExpression.firstMatch(in: path, range: range) == nil
    }

    private static func unwrapped(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last else {
            return value
        }

        let isPair = (first == "\"" && last == "\"")
            || (first == "'" && last == "'")
            || (first == "<" && last == ">")
            || (first == "(" && last == ")")
        guard isPair else { return value }
        return String(value.dropFirst().dropLast())
    }
}

public enum TerminalWorkspacePathResolutionError: Error, Equatable, LocalizedError {
    case workspaceUnavailable
    case invalidReference
    case outsideWorkspace
    case notFound
    case notRegularFile
    case ambiguous([String])

    public var errorDescription: String? {
        switch self {
        case .workspaceUnavailable:
            return "The workspace is not available."
        case .invalidReference:
            return "The terminal path is not valid."
        case .outsideWorkspace:
            return "Terminal paths must stay inside the current workspace."
        case .notFound:
            return "The terminal path does not match a workspace file."
        case .notRegularFile:
            return "The terminal path does not point to a file."
        case .ambiguous:
            return "The terminal path matches more than one workspace file."
        }
    }
}

public enum TerminalWorkspacePathResolver {
    public static func resolve(
        _ reference: TerminalFileReference,
        workspaceURL: URL,
        knownDocumentURLs: [URL] = [],
        fileManager: FileManager = .default
    ) throws -> ResolvedTerminalFileReference {
        guard !reference.path.isEmpty else {
            throw TerminalWorkspacePathResolutionError.invalidReference
        }

        let canonicalWorkspace = try canonicalWorkspace(
            workspaceURL,
            fileManager: fileManager
        )
        let directURL = candidateURL(for: reference.path, workspaceURL: canonicalWorkspace)

        if reference.path.hasPrefix("/"), fileManager.fileExists(atPath: directURL.path) {
            let canonicalURL = try canonicalWorkspaceURL(
                for: directURL,
                workspaceURL: canonicalWorkspace,
                fileManager: fileManager
            )
            try requireRegularFile(canonicalURL, fileManager: fileManager)
            return ResolvedTerminalFileReference(
                url: canonicalURL,
                line: reference.line,
                column: reference.column
            )
        }

        let relativeComponents = relativePathComponents(reference.path)
        guard !reference.path.hasPrefix("/"),
              !relativeComponents.contains("..")
        else {
            if isContained(directURL.resolvingSymlinksInPath(), in: canonicalWorkspace) {
                throw TerminalWorkspacePathResolutionError.notFound
            }
            throw TerminalWorkspacePathResolutionError.outsideWorkspace
        }

        let requestedComponents = relativeComponents.filter { $0 != "." }
        guard !requestedComponents.isEmpty else {
            throw TerminalWorkspacePathResolutionError.invalidReference
        }

        var matchesByPath: [String: URL] = [:]
        if fileManager.fileExists(atPath: directURL.path) {
            let canonicalURL = try canonicalWorkspaceURL(
                for: directURL,
                workspaceURL: canonicalWorkspace,
                fileManager: fileManager
            )
            try requireRegularFile(canonicalURL, fileManager: fileManager)
            matchesByPath[canonicalURL.path] = canonicalURL
        }
        for documentURL in knownDocumentURLs {
            let documentComponents = documentURL.standardizedFileURL.pathComponents
            guard documentComponents.count >= requestedComponents.count,
                  Array(documentComponents.suffix(requestedComponents.count)) == requestedComponents,
                  fileManager.fileExists(atPath: documentURL.path),
                  let canonicalURL = try? canonicalWorkspaceURL(
                      for: documentURL,
                      workspaceURL: canonicalWorkspace,
                      fileManager: fileManager
                  ),
                  (try? requireRegularFile(canonicalURL, fileManager: fileManager)) != nil
            else {
                continue
            }
            matchesByPath[canonicalURL.path] = canonicalURL
        }

        let matches = matchesByPath.values.sorted { $0.path < $1.path }
        guard !matches.isEmpty else {
            throw TerminalWorkspacePathResolutionError.notFound
        }
        guard matches.count == 1, let match = matches.first else {
            throw TerminalWorkspacePathResolutionError.ambiguous(matches.map(\.path))
        }

        return ResolvedTerminalFileReference(
            url: match,
            line: reference.line,
            column: reference.column
        )
    }

    /// Resolves an existing file-system item and enforces the workspace boundary.
    /// The returned URL contains no symbolic-link components.
    public static func canonicalWorkspaceURL(
        for url: URL,
        workspaceURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let canonicalWorkspace = try canonicalWorkspace(
            workspaceURL,
            fileManager: fileManager
        )
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw TerminalWorkspacePathResolutionError.notFound
        }
        guard isContained(candidate, in: canonicalWorkspace) else {
            throw TerminalWorkspacePathResolutionError.outsideWorkspace
        }
        return candidate
    }

    private static func canonicalWorkspace(
        _ workspaceURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let canonicalWorkspace = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: canonicalWorkspace.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw TerminalWorkspacePathResolutionError.workspaceUnavailable
        }
        return canonicalWorkspace
    }

    private static func candidateURL(for path: String, workspaceURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return workspaceURL.appendingPathComponent(path).standardizedFileURL
    }

    private static func requireRegularFile(_ url: URL, fileManager: FileManager) throws {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
            throw TerminalWorkspacePathResolutionError.notRegularFile
        }
    }

    private static func relativePathComponents(_ path: String) -> [String] {
        (path as NSString).pathComponents.filter { component in
            component != "/" && !component.isEmpty
        }
    }

    private static func isContained(_ candidate: URL, in workspace: URL) -> Bool {
        let workspaceComponents = workspace.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= workspaceComponents.count else { return false }
        return Array(candidateComponents.prefix(workspaceComponents.count)) == workspaceComponents
    }
}

public enum TerminalShellArgument {
    public static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum TerminalSourceLocationValidator {
    public static func location(
        line: Int,
        column: Int?,
        in text: String
    ) -> MarkdownSourceLocation? {
        let offset = (column ?? 1) - 1
        guard line > 0, offset >= 0 else { return nil }

        let source = text as NSString
        var currentLine = 1
        var lineStart = 0
        while currentLine < line, lineStart < source.length {
            let range = source.lineRange(for: NSRange(location: lineStart, length: 0))
            let next = NSMaxRange(range)
            guard next > lineStart else { return nil }
            lineStart = next
            currentLine += 1
        }
        guard currentLine == line,
              line == 1 || lineStart < source.length
        else { return nil }

        let lineRange = source.lineRange(
            for: NSRange(location: min(lineStart, source.length), length: 0)
        )
        var contentEnd = min(NSMaxRange(lineRange), source.length)
        while contentEnd > lineStart {
            let character = source.character(at: contentEnd - 1)
            guard character == 0x0A || character == 0x0D else { break }
            contentEnd -= 1
        }
        guard offset <= contentEnd - lineStart else { return nil }
        return MarkdownSourceLocation(line: line, offset: offset)
    }
}

public enum TerminalInsertionRequestError: Error, Equatable, LocalizedError {
    case invalidSerial
    case emptyText
    case textTooLarge(maximumBytes: Int)
    case unsafeControlCharacter(UInt32)

    public var errorDescription: String? {
        switch self {
        case .invalidSerial:
            return "The terminal insertion request is invalid."
        case .emptyText:
            return "There is no text to insert into the terminal."
        case .textTooLarge(let maximumBytes):
            return "Terminal insertion is limited to \(maximumBytes) bytes."
        case .unsafeControlCharacter:
            return "The text contains a control character that cannot be inserted safely."
        }
    }
}

public struct TerminalInsertionRequest: Equatable, Sendable {
    public static let maximumTextBytes = 1_048_576

    public let serial: UInt64
    public let text: String

    public init(serial: UInt64, text: String) throws {
        guard serial > 0 else {
            throw TerminalInsertionRequestError.invalidSerial
        }
        guard !text.isEmpty else {
            throw TerminalInsertionRequestError.emptyText
        }
        guard text.utf8.count <= Self.maximumTextBytes else {
            throw TerminalInsertionRequestError.textTooLarge(
                maximumBytes: Self.maximumTextBytes
            )
        }
        if let unsafeScalar = text.unicodeScalars.first(where: { scalar in
            (scalar.value < 0x20 && scalar.value != 0x09 && scalar.value != 0x0A)
                || scalar.value == 0x7F
        }) {
            throw TerminalInsertionRequestError.unsafeControlCharacter(unsafeScalar.value)
        }

        self.serial = serial
        self.text = text
    }
}

public enum TerminalInsertionOutcome: String, Equatable, Sendable {
    case inserted
    case bracketedPasteRequired
    case unavailable
}
