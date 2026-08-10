import Foundation

public enum WorkspaceFileIdentity {
    public static func isCaseOnlyRename(from sourceURL: URL, to destinationURL: URL) -> Bool {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard source.path != destination.path,
              source.path.compare(destination.path, options: .caseInsensitive) == .orderedSame,
              FileManager.default.fileExists(atPath: source.path),
              FileManager.default.fileExists(atPath: destination.path),
              let sourceValues = try? source.resourceValues(forKeys: [
                  .fileResourceIdentifierKey,
                  .volumeSupportsCaseSensitiveNamesKey,
              ]),
              sourceValues.volumeSupportsCaseSensitiveNames == false,
              let sourceIdentifier = sourceValues.fileResourceIdentifier,
              let destinationIdentifier = try? destination.resourceValues(
                  forKeys: [.fileResourceIdentifierKey]
              ).fileResourceIdentifier
        else { return false }

        return (sourceIdentifier as? NSObject)?.isEqual(destinationIdentifier) == true
    }
}

public struct MarkdownLinkMoveFileStamp: Equatable, Sendable {
    public let canonicalPath: String
    public let systemNumber: UInt64
    public let fileNumber: UInt64
    public let modificationDate: Date?
    public let fileSize: UInt64?
    public let isDirectory: Bool

    public static func read(from url: URL) throws -> MarkdownLinkMoveFileStamp {
        let standardizedURL = url.standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: standardizedURL.path)
        guard let systemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            throw CocoaError(.fileReadUnknown)
        }
        return MarkdownLinkMoveFileStamp(
            canonicalPath: standardizedURL.resolvingSymlinksInPath().path,
            systemNumber: systemNumber,
            fileNumber: fileNumber,
            modificationDate: attributes[.modificationDate] as? Date,
            fileSize: (attributes[.size] as? NSNumber)?.uint64Value,
            isDirectory: attributes[.type] as? FileAttributeType == .typeDirectory
        )
    }
}

public struct MarkdownLinkRewrite: Equatable, Sendable {
    public let sourceRange: MarkdownSourceRange
    public let oldDestination: String
    public let newDestination: String

    public init(sourceRange: MarkdownSourceRange, oldDestination: String, newDestination: String) {
        self.sourceRange = sourceRange
        self.oldDestination = oldDestination
        self.newDestination = newDestination
    }
}

public struct MarkdownLinkRewriteFilePlan: Equatable, Sendable {
    public let originalURL: URL
    public let finalURL: URL
    public let originalRevision: WorkspaceTextRevision
    public let updatedText: String
    public let rewrites: [MarkdownLinkRewrite]

    public init(
        originalURL: URL,
        finalURL: URL,
        originalRevision: WorkspaceTextRevision,
        updatedText: String,
        rewrites: [MarkdownLinkRewrite]
    ) {
        self.originalURL = originalURL
        self.finalURL = finalURL
        self.originalRevision = originalRevision
        self.updatedText = updatedText
        self.rewrites = rewrites
    }
}

public struct MarkdownLinkExaminedFile: Equatable, Sendable {
    public let url: URL
    public let revision: WorkspaceTextRevision

    public init(url: URL, revision: WorkspaceTextRevision) {
        self.url = url
        self.revision = revision
    }
}

public struct MarkdownLinkMovePlan: Equatable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let sourceStamp: MarkdownLinkMoveFileStamp
    public let destinationParentStamp: MarkdownLinkMoveFileStamp
    public let examinedFiles: [MarkdownLinkExaminedFile]
    public let rewriteFiles: [MarkdownLinkRewriteFilePlan]

    public init(
        sourceURL: URL,
        destinationURL: URL,
        sourceStamp: MarkdownLinkMoveFileStamp,
        destinationParentStamp: MarkdownLinkMoveFileStamp,
        examinedFiles: [MarkdownLinkExaminedFile],
        rewriteFiles: [MarkdownLinkRewriteFilePlan]
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.sourceStamp = sourceStamp
        self.destinationParentStamp = destinationParentStamp
        self.examinedFiles = examinedFiles
        self.rewriteFiles = rewriteFiles
    }

    public var rewriteCount: Int {
        rewriteFiles.reduce(0) { $0 + $1.rewrites.count }
    }
}

public enum MarkdownLinkMovePlannerError: LocalizedError, Equatable {
    case sourceOutsideWorkspace
    case destinationOutsideWorkspace
    case destinationExists
    case sourceMissing
    case unsafeLink(String)

    public var errorDescription: String? {
        switch self {
        case .sourceOutsideWorkspace:
            return "The item to move is outside the workspace."
        case .destinationOutsideWorkspace:
            return "The destination is outside the workspace."
        case .destinationExists:
            return "An item already exists at the destination."
        case .sourceMissing:
            return "The item to move no longer exists."
        case .unsafeLink(let destination):
            return "The link destination \(destination) could not be rewritten safely."
        }
    }
}

public struct MarkdownLinkMovePlanner: Sendable {
    private let parser = MarkdownWorkspaceLinkParser()
    private let resolver = MarkdownWorkspaceLinkResolver()

    public init() {}

    public func plan(
        moving sourceURL: URL,
        to destinationURL: URL,
        workspaceRootURL: URL,
        documents: [WorkspaceDocument]
    ) throws -> MarkdownLinkMovePlan {
        let root = canonical(workspaceRootURL)
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard isContained(canonical(source), in: root) else {
            throw MarkdownLinkMovePlannerError.sourceOutsideWorkspace
        }
        guard isContained(canonical(destination), in: root) else {
            throw MarkdownLinkMovePlannerError.destinationOutsideWorkspace
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw MarkdownLinkMovePlannerError.sourceMissing
        }
        guard let sourceStamp = try? MarkdownLinkMoveFileStamp.read(from: source) else {
            throw MarkdownLinkMovePlannerError.sourceMissing
        }
        guard let destinationParentStamp = try? MarkdownLinkMoveFileStamp.read(
            from: destination.deletingLastPathComponent()
        ) else {
            throw MarkdownLinkMovePlannerError.destinationOutsideWorkspace
        }
        guard destinationParentStamp.isDirectory else {
            throw MarkdownLinkMovePlannerError.destinationOutsideWorkspace
        }
        let destinationExists = FileManager.default.fileExists(atPath: destination.path)
        guard !destinationExists
                || WorkspaceFileIdentity.isCaseOnlyRename(from: source, to: destination)
        else {
            throw MarkdownLinkMovePlannerError.destinationExists
        }

        let markdownDocuments = documents.filter { $0.kind == .markdown }
        let documentByCanonicalPath = Dictionary(
            markdownDocuments.map { (canonical($0.url).path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var examinedFiles: [MarkdownLinkExaminedFile] = []
        var rewriteFiles: [MarkdownLinkRewriteFilePlan] = []

        for document in markdownDocuments.sorted(by: { $0.relativePath < $1.relativePath }) {
            try Task.checkCancellation()
            try WorkspaceTextFileGuard.ensureWithinLimit(at: document.url)
            let revision = try WorkspaceConditionalTextWriter.read(from: document.url)
            examinedFiles.append(MarkdownLinkExaminedFile(url: document.url, revision: revision))

            let newSourceURL = movedURL(
                document.url,
                sourceURL: source,
                destinationURL: destination
            ) ?? document.url
            var replacements: [(range: NSRange, rewrite: MarkdownLinkRewrite)] = []

            for link in parser.links(in: revision.text) {
                guard link.kind != .referenceUsage else { continue }
                guard let oldTargetURL = resolvedTargetURL(
                    for: link,
                    sourceDocument: document,
                    root: root,
                    documents: documents,
                    documentByCanonicalPath: documentByCanonicalPath
                ) else { continue }

                let newTargetURL = movedURL(
                    oldTargetURL,
                    sourceURL: source,
                    destinationURL: destination
                ) ?? oldTargetURL
                guard newSourceURL.standardizedFileURL != document.url.standardizedFileURL
                        || newTargetURL.standardizedFileURL != oldTargetURL.standardizedFileURL
                else { continue }

                let newPath = try rewrittenPath(
                    for: link,
                    newSourceURL: newSourceURL,
                    newTargetURL: newTargetURL,
                    root: root
                )
                let newDestination = link.destinationComponents.replacingPath(with: newPath)
                guard newDestination != link.destination else { continue }
                let rewrite = MarkdownLinkRewrite(
                    sourceRange: link.destinationRange,
                    oldDestination: link.destination,
                    newDestination: newDestination
                )
                replacements.append((link.destinationRange.nsRange, rewrite))
            }

            guard !replacements.isEmpty else { continue }
            let updated = NSMutableString(string: revision.text)
            for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
                guard NSMaxRange(replacement.range) <= updated.length,
                      updated.substring(with: replacement.range) == replacement.rewrite.oldDestination
                else {
                    throw MarkdownLinkMovePlannerError.unsafeLink(replacement.rewrite.oldDestination)
                }
                updated.replaceCharacters(
                    in: replacement.range,
                    with: replacement.rewrite.newDestination
                )
            }
            rewriteFiles.append(MarkdownLinkRewriteFilePlan(
                originalURL: document.url,
                finalURL: newSourceURL,
                originalRevision: revision,
                updatedText: String(updated),
                rewrites: replacements.map(\.rewrite).sorted {
                    $0.sourceRange.location < $1.sourceRange.location
                }
            ))
        }

        return MarkdownLinkMovePlan(
            sourceURL: source,
            destinationURL: destination,
            sourceStamp: sourceStamp,
            destinationParentStamp: destinationParentStamp,
            examinedFiles: examinedFiles,
            rewriteFiles: rewriteFiles
        )
    }

    private func resolvedTargetURL(
        for link: MarkdownWorkspaceLink,
        sourceDocument: WorkspaceDocument,
        root: URL,
        documents: [WorkspaceDocument],
        documentByCanonicalPath: [String: WorkspaceDocument]
    ) -> URL? {
        if link.kind == .markdown || link.kind == .wikilink {
            switch resolver.resolve(
                link,
                sourceDocument: sourceDocument,
                workspaceRootURL: root,
                documents: documents
            ) {
            case .document(let documentID, _):
                return documents.first(where: { $0.id == documentID })?.url
            case .external, .ambiguous, .missing, .invalid:
                break
            }
        }

        let components = link.destinationComponents
        guard !components.path.isEmpty,
              !components.path.contains("\0"),
              let decodedPath = components.path.removingPercentEncoding
        else { return nil }
        if let scheme = URLComponents(string: components.path)?.scheme {
            guard scheme.lowercased() == "file",
                  let fileURL = URL(string: components.path),
                  fileURL.isFileURL
            else { return nil }
            let candidate = canonical(fileURL)
            return isContained(candidate, in: root) ? candidate : nil
        }

        let candidate: URL
        if decodedPath.hasPrefix("/") {
            candidate = root.appendingPathComponent(String(decodedPath.drop(while: { $0 == "/" })))
        } else {
            let relative = sourceDocument.url.deletingLastPathComponent().appendingPathComponent(decodedPath)
            let rooted = root.appendingPathComponent(decodedPath)
            if FileManager.default.fileExists(atPath: relative.path) {
                candidate = relative
            } else if FileManager.default.fileExists(atPath: rooted.path) {
                candidate = rooted
            } else {
                return nil
            }
        }
        let canonicalCandidate = canonical(candidate)
        guard isContained(canonicalCandidate, in: root) else { return nil }
        if documentByCanonicalPath[canonicalCandidate.path] != nil
            || FileManager.default.fileExists(atPath: canonicalCandidate.path) {
            return canonicalCandidate
        }
        return nil
    }

    private func rewrittenPath(
        for link: MarkdownWorkspaceLink,
        newSourceURL: URL,
        newTargetURL: URL,
        root: URL
    ) throws -> String {
        let originalPath = link.destinationComponents.path
        if originalPath.isEmpty {
            return ""
        }
        if originalPath.lowercased().hasPrefix("file:") {
            return newTargetURL.absoluteURL.absoluteString
        }

        let rooted = originalPath.hasPrefix("/")
        var path = rooted
            ? relativePath(from: root, to: newTargetURL)
            : relativePath(from: newSourceURL.deletingLastPathComponent(), to: newTargetURL)

        if link.kind == .wikilink,
           (originalPath as NSString).pathExtension.isEmpty,
           WorkspaceDocumentSupport.markdownExtensions.contains(newTargetURL.pathExtension.lowercased()) {
            path = (path as NSString).deletingPathExtension
        }

        if link.kind != .wikilink {
            path = path.split(separator: "/", omittingEmptySubsequences: false)
                .map { component in
                    String(component).addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowed)
                        ?? String(component)
                }
                .joined(separator: "/")
        }
        guard !path.isEmpty else {
            throw MarkdownLinkMovePlannerError.unsafeLink(link.destination)
        }
        return rooted ? "/" + path : path
    }

    private func movedURL(_ url: URL, sourceURL: URL, destinationURL: URL) -> URL? {
        let candidate = url.standardizedFileURL
        let sourceComponents = sourceURL.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= sourceComponents.count,
              Array(candidateComponents.prefix(sourceComponents.count)) == sourceComponents
        else { return nil }
        let suffix = candidateComponents.dropFirst(sourceComponents.count)
        return suffix.reduce(destinationURL) { partial, component in
            partial.appendingPathComponent(component)
        }
    }

    private func relativePath(from directory: URL, to target: URL) -> String {
        let from = directory.standardizedFileURL.pathComponents
        let to = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] {
            common += 1
        }
        let upward = Array(repeating: "..", count: from.count - common)
        let downward = Array(to.dropFirst(common))
        return (upward + downward).joined(separator: "/")
    }

    private func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static let pathComponentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return allowed
    }()
}
