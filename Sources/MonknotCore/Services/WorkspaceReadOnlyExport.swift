import Foundation

public struct WorkspaceReadOnlyExportRequest: Codable, Sendable {
    public let command: String
    public let root: String
    public let query: String?
    public let relativePath: String?

    public init(command: String, root: String, query: String? = nil, relativePath: String? = nil) {
        self.command = command
        self.root = root
        self.query = query
        self.relativePath = relativePath
    }
}

public struct WorkspaceReadOnlyExportDocument: Codable, Sendable, Equatable {
    public let id: String
    public let relativePath: String
    public let kind: String
    public let canEditText: Bool
    public let canSearch: Bool

    public init(document: WorkspaceDocument) {
        id = document.id
        relativePath = document.relativePath
        kind = document.kind.rawValue
        canEditText = document.capabilities.canEditText
        canSearch = document.capabilities.canSearchText || document.capabilities.canSearchPDF
    }
}

public struct WorkspaceReadOnlyExportSearchHit: Codable, Sendable, Equatable {
    public let relativePath: String
    public let kind: String
    public let line: Int
    public let column: Int
    public let preview: String

    public init(result: WorkspaceSearchResult) {
        relativePath = result.relativePath
        kind = result.kind.rawValue
        line = result.line
        column = result.column
        preview = result.preview
    }
}

public struct WorkspaceReadOnlyExportFileContent: Codable, Sendable, Equatable {
    public let relativePath: String
    public let kind: String
    public let lineCount: Int
    public let content: String

    public init(relativePath: String, kind: String, lineCount: Int, content: String) {
        self.relativePath = relativePath
        self.kind = kind
        self.lineCount = lineCount
        self.content = content
    }
}

public struct WorkspaceReadOnlyExportCapabilities: Codable, Sendable, Equatable {
    public let commands: [String]
    public let protocolVersion: Int

    public init(commands: [String], protocolVersion: Int = 1) {
        self.commands = commands
        self.protocolVersion = protocolVersion
    }
}

public struct WorkspaceReadOnlyExportResponse: Codable, Sendable {
    public let documents: [WorkspaceReadOnlyExportDocument]?
    public let results: [WorkspaceReadOnlyExportSearchHit]?
    public let skippedLargeFileCount: Int?
    public let file: WorkspaceReadOnlyExportFileContent?
    public let capabilities: WorkspaceReadOnlyExportCapabilities?
    public let tree: String?

    public init(documents: [WorkspaceReadOnlyExportDocument]) {
        self.documents = documents
        self.results = nil
        self.skippedLargeFileCount = nil
        self.file = nil
        self.capabilities = nil
        self.tree = nil
    }

    public init(results: [WorkspaceReadOnlyExportSearchHit], skippedLargeFileCount: Int) {
        self.documents = nil
        self.results = results
        self.skippedLargeFileCount = skippedLargeFileCount
        self.file = nil
        self.capabilities = nil
        self.tree = nil
    }

    public init(file: WorkspaceReadOnlyExportFileContent) {
        self.documents = nil
        self.results = nil
        self.skippedLargeFileCount = nil
        self.file = file
        self.capabilities = nil
        self.tree = nil
    }

    public init(capabilities: WorkspaceReadOnlyExportCapabilities) {
        self.documents = nil
        self.results = nil
        self.skippedLargeFileCount = nil
        self.file = nil
        self.capabilities = capabilities
        self.tree = nil
    }

    public init(tree: String) {
        self.documents = nil
        self.results = nil
        self.skippedLargeFileCount = nil
        self.file = nil
        self.capabilities = nil
        self.tree = tree
    }
}

public struct WorkspaceReadOnlyExportService: Sendable {
    private let scanner: any WorkspaceDocumentScanning
    private let searchService: WorkspaceSearchService
    private let treeFormatter: WorkspaceTreeFormatter

    public init(
        scanner: any WorkspaceDocumentScanning = WorkspaceDocumentScanner(),
        searchService: WorkspaceSearchService = WorkspaceSearchService(),
        treeFormatter: WorkspaceTreeFormatter = WorkspaceTreeFormatter()
    ) {
        self.scanner = scanner
        self.searchService = searchService
        self.treeFormatter = treeFormatter
    }

    public func handle(requestData: Data) throws -> Data {
        let request = try JSONDecoder().decode(WorkspaceReadOnlyExportRequest.self, from: requestData)
        let rootURL = URL(fileURLWithPath: request.root, isDirectory: true)

        switch request.command {
        case "capabilities":
            return try JSONEncoder().encode(
                WorkspaceReadOnlyExportResponse(
                    capabilities: WorkspaceReadOnlyExportCapabilities(
                        commands: Self.supportedCommands
                    )
                )
            )
        case "list_documents":
            let scan = try scanner.scan(rootURL: rootURL)
            let documents = scan.documents.map(WorkspaceReadOnlyExportDocument.init(document:))
            return try JSONEncoder().encode(WorkspaceReadOnlyExportResponse(documents: documents))
        case "tree":
            let scan = try scanner.scan(rootURL: rootURL)
            let tree = treeFormatter.compactTree(from: scan.root)
            return try JSONEncoder().encode(WorkspaceReadOnlyExportResponse(tree: tree))
        case "search":
            guard let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                throw Error.missingQuery
            }
            let scan = try scanner.scan(rootURL: rootURL)
            let batch = try searchService.search(query: query, documents: scan.documents)
            let hits = batch.results.map(WorkspaceReadOnlyExportSearchHit.init(result:))
            return try JSONEncoder().encode(
                WorkspaceReadOnlyExportResponse(
                    results: hits,
                    skippedLargeFileCount: batch.skippedLargeFileCount
                )
            )
        case "read_file":
            guard let relativePath = request.relativePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !relativePath.isEmpty else {
                throw Error.missingRelativePath
            }
            let fileURL = try Self.resolveFileURL(rootURL: rootURL, relativePath: relativePath)
            let scan = try scanner.scan(rootURL: rootURL)
            guard let document = scan.documents.first(where: { $0.relativePath == relativePath }) else {
                throw Error.fileNotFound(relativePath)
            }
            guard document.capabilities.canSearchText else {
                throw Error.unreadableFile(relativePath)
            }
            let content = try WorkspaceTextFileGuard.readUTF8Text(from: fileURL)
            let lineCount = max(1, content.split(separator: "\n", omittingEmptySubsequences: false).count)
            return try JSONEncoder().encode(
                WorkspaceReadOnlyExportResponse(
                    file: WorkspaceReadOnlyExportFileContent(
                        relativePath: relativePath,
                        kind: document.kind.rawValue,
                        lineCount: lineCount,
                        content: content
                    )
                )
            )
        default:
            throw Error.unsupportedCommand(request.command)
        }
    }

    public static let supportedCommands = [
        "capabilities",
        "list_documents",
        "tree",
        "search",
        "read_file"
    ]

    static func resolveFileURL(rootURL: URL, relativePath: String) throws -> URL {
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)

        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Error.invalidRelativePath(relativePath)
        }

        let normalized = components.joined(separator: "/")
        let candidate = rootURL.appendingPathComponent(normalized).standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidate.path.hasPrefix(prefix) else {
            throw Error.invalidRelativePath(relativePath)
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw Error.fileNotFound(relativePath)
        }
        return candidate
    }

    public enum Error: Swift.Error, Equatable {
        case unsupportedCommand(String)
        case missingQuery
        case missingRelativePath
        case invalidRelativePath(String)
        case fileNotFound(String)
        case unreadableFile(String)
    }
}
