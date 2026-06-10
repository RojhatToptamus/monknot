import Foundation
import UniformTypeIdentifiers

public enum WorkspaceDocumentKind: String, Codable, Sendable {
    case markdown
    case pdf
    case text
    case media
    case nativePreview
    case unsupported
}

public struct WorkspaceDocumentCapabilities: Codable, Hashable, Sendable {
    public let canPreview: Bool
    public let canEditText: Bool
    public let canSearchText: Bool
    public let canSearchPDF: Bool
    public let canExportPDF: Bool
    public let canShowOutline: Bool
    public let canPreviewHTML: Bool

    public init(
        canPreview: Bool,
        canEditText: Bool,
        canSearchText: Bool,
        canSearchPDF: Bool,
        canExportPDF: Bool,
        canShowOutline: Bool,
        canPreviewHTML: Bool = false
    ) {
        self.canPreview = canPreview
        self.canEditText = canEditText
        self.canSearchText = canSearchText
        self.canSearchPDF = canSearchPDF
        self.canExportPDF = canExportPDF
        self.canShowOutline = canShowOutline
        self.canPreviewHTML = canPreviewHTML
    }
}

public struct WorkspaceDocument: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let url: URL
    public let displayName: String
    public let relativePath: String
    public let kind: WorkspaceDocumentKind
    public let contentTypeIdentifier: String?
    public let localizedTypeDescription: String?
    public let capabilities: WorkspaceDocumentCapabilities
    public let depth: Int

    public init(url: URL, rootURL: URL) {
        let standardizedURL = url.standardizedFileURL
        let classification = WorkspaceDocumentSupport.classification(for: standardizedURL)
        self.init(url: standardizedURL, rootURL: rootURL, classification: classification)
    }

    init(url: URL, rootURL: URL, classification: WorkspaceDocumentSupport.Classification) {
        let standardizedURL = url.standardizedFileURL
        self.url = standardizedURL
        self.id = standardizedURL.path
        self.displayName = standardizedURL.lastPathComponent
        self.relativePath = WorkspaceDocumentSupport.relativePath(for: standardizedURL, in: rootURL)
        self.kind = classification.kind
        self.contentTypeIdentifier = classification.contentTypeIdentifier
        self.localizedTypeDescription = classification.localizedTypeDescription
        self.capabilities = classification.capabilities
        self.depth = max(0, relativePath.split(separator: "/").count - 1)
    }
}

public enum WorkspaceDocumentSupport {
    public struct Classification: Equatable, Sendable {
        public let kind: WorkspaceDocumentKind
        public let contentTypeIdentifier: String?
        public let localizedTypeDescription: String?
        public let capabilities: WorkspaceDocumentCapabilities
    }

    public static let markdownExtensions: Set<String> = [
        "md",
        "markdown",
        "mdown",
        "mkd"
    ]
    public static let pdfExtensions: Set<String> = ["pdf"]
    public static let htmlExtensions: Set<String> = ["html", "htm"]
    public static let textExtensions: Set<String> = [
        "txt", "text", "log",
        "mmd", "mermaid", "mdx",
        "swift", "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "java", "kt",
        "c", "h", "cpp", "cxx", "cc", "hpp", "m", "mm", "php",
        "sh", "bash", "zsh", "fish",
        "sql", "graphql", "gql", "proto", "dockerfile",
        "css", "scss", "sass", "less",
        "json", "jsonc", "yaml", "yml", "xml", "csv", "tsv", "toml", "ini", "env"
    ]
    public static let textFilenames: Set<String> = [
        "dockerfile", "makefile", "procfile", "gemfile", "rakefile", "justfile"
    ]
    public static let ignoredUnsupportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "tif", "tiff", "webp", "bmp", "ico",
        "mov", "mp4", "m4v", "avi", "mpg", "mpeg",
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac",
        "zip", "rar", "7z", "tar", "gz", "bz2", "xz",
        "webarchive", "rtf", "rtfd",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        "epub"
    ]
    public static let supportedExtensions = markdownExtensions
        .union(pdfExtensions)
        .union(htmlExtensions)
        .union(textExtensions)

    public static func shouldIncludeInWorkspaceScan(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        let filename = url.lastPathComponent.lowercased()

        if ignoredUnsupportedExtensions.contains(fileExtension) {
            return false
        }

        if supportedExtensions.contains(fileExtension) || textFilenames.contains(filename) {
            return true
        }

        guard let type = UTType(filenameExtension: fileExtension) else {
            return false
        }

        return type.conforms(to: .pdf) ||
            type.conforms(to: .html) ||
            type.conforms(to: .text) ||
            type.conforms(to: .plainText) ||
            type.conforms(to: .sourceCode)
    }

    public static func kind(for url: URL) -> WorkspaceDocumentKind? {
        let kind = classification(for: url).kind
        return kind == .unsupported ? nil : kind
    }

    public static func classification(for url: URL) -> Classification {
        let fileExtension = url.pathExtension.lowercased()
        let filename = url.lastPathComponent.lowercased()
        let type = UTType(filenameExtension: fileExtension)
        let contentTypeIdentifier = type?.identifier
        let localizedTypeDescription = type?.localizedDescription

        if markdownExtensions.contains(fileExtension) {
            return Classification(
                kind: .markdown,
                contentTypeIdentifier: contentTypeIdentifier,
                localizedTypeDescription: localizedTypeDescription,
                capabilities: capabilities(for: .markdown)
            )
        }

        if pdfExtensions.contains(fileExtension) || type?.conforms(to: .pdf) == true {
            return Classification(
                kind: .pdf,
                contentTypeIdentifier: contentTypeIdentifier,
                localizedTypeDescription: localizedTypeDescription,
                capabilities: capabilities(for: .pdf)
            )
        }

        if htmlExtensions.contains(fileExtension) || type?.conforms(to: .html) == true {
            return Classification(
                kind: .text,
                contentTypeIdentifier: contentTypeIdentifier,
                localizedTypeDescription: localizedTypeDescription,
                capabilities: htmlCapabilities()
            )
        }

        if textExtensions.contains(fileExtension) || textFilenames.contains(filename) {
            return Classification(
                kind: .text,
                contentTypeIdentifier: contentTypeIdentifier,
                localizedTypeDescription: localizedTypeDescription,
                capabilities: capabilities(for: .text)
            )
        }

        if type?.conforms(to: .text) == true ||
            type?.conforms(to: .plainText) == true ||
            type?.conforms(to: .sourceCode) == true {
            return Classification(
                kind: .text,
                contentTypeIdentifier: contentTypeIdentifier,
                localizedTypeDescription: localizedTypeDescription,
                capabilities: capabilities(for: .text)
            )
        }

        return Classification(
            kind: .unsupported,
            contentTypeIdentifier: contentTypeIdentifier,
            localizedTypeDescription: localizedTypeDescription,
            capabilities: capabilities(for: .unsupported)
        )
    }

    public static func capabilities(for kind: WorkspaceDocumentKind) -> WorkspaceDocumentCapabilities {
        switch kind {
        case .markdown:
            return WorkspaceDocumentCapabilities(
                canPreview: true,
                canEditText: true,
                canSearchText: true,
                canSearchPDF: false,
                canExportPDF: true,
                canShowOutline: true,
                canPreviewHTML: false
            )
        case .pdf:
            return WorkspaceDocumentCapabilities(
                canPreview: true,
                canEditText: false,
                canSearchText: false,
                canSearchPDF: true,
                canExportPDF: false,
                canShowOutline: false,
                canPreviewHTML: false
            )
        case .text:
            return WorkspaceDocumentCapabilities(
                canPreview: true,
                canEditText: true,
                canSearchText: true,
                canSearchPDF: false,
                canExportPDF: false,
                canShowOutline: false,
                canPreviewHTML: false
            )
        case .media:
            return WorkspaceDocumentCapabilities(
                canPreview: false,
                canEditText: false,
                canSearchText: false,
                canSearchPDF: false,
                canExportPDF: false,
                canShowOutline: false,
                canPreviewHTML: false
            )
        case .nativePreview:
            return WorkspaceDocumentCapabilities(
                canPreview: false,
                canEditText: false,
                canSearchText: false,
                canSearchPDF: false,
                canExportPDF: false,
                canShowOutline: false,
                canPreviewHTML: false
            )
        case .unsupported:
            return WorkspaceDocumentCapabilities(
                canPreview: false,
                canEditText: false,
                canSearchText: false,
                canSearchPDF: false,
                canExportPDF: false,
                canShowOutline: false,
                canPreviewHTML: false
            )
        }
    }

    private static func htmlCapabilities() -> WorkspaceDocumentCapabilities {
        WorkspaceDocumentCapabilities(
            canPreview: true,
            canEditText: true,
            canSearchText: true,
            canSearchPDF: false,
            canExportPDF: false,
            canShowOutline: false,
            canPreviewHTML: true
        )
    }

    public static func isWorkspaceDocument(_ url: URL) -> Bool {
        kind(for: url) != nil
    }

    public static func isMarkdownDocument(_ url: URL) -> Bool {
        classification(for: url).kind == .markdown
    }

    public static func isPDFDocument(_ url: URL) -> Bool {
        classification(for: url).kind == .pdf
    }

    public static func displayName(forRelativePath relativePath: String) -> String {
        URL(fileURLWithPath: relativePath).lastPathComponent
    }

    public static func relativePath(for url: URL, in rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        guard filePath.hasPrefix(prefix) else {
            return url.lastPathComponent
        }

        return String(filePath.dropFirst(prefix.count))
    }
}
