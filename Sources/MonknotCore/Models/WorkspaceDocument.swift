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
    public let usesQuickLookPreview: Bool

    public init(
        canPreview: Bool,
        canEditText: Bool,
        canSearchText: Bool,
        canSearchPDF: Bool,
        canExportPDF: Bool,
        canShowOutline: Bool,
        usesQuickLookPreview: Bool
    ) {
        self.canPreview = canPreview
        self.canEditText = canEditText
        self.canSearchText = canSearchText
        self.canSearchPDF = canSearchPDF
        self.canExportPDF = canExportPDF
        self.canShowOutline = canShowOutline
        self.usesQuickLookPreview = usesQuickLookPreview
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
    public static let textExtensions: Set<String> = [
        "txt", "text", "log",
        "swift", "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "java", "kt",
        "c", "h", "cpp", "cxx", "cc", "hpp", "m", "mm", "php",
        "sh", "bash", "zsh", "fish",
        "css", "scss", "sass", "less",
        "json", "yaml", "yml", "xml", "csv", "tsv", "toml", "ini", "env"
    ]
    public static let nativePreviewExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "tif", "tiff", "webp", "bmp", "ico",
        "html", "htm", "webarchive",
        "rtf", "rtfd",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        "epub"
    ]
    public static let mediaExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mpg", "mpeg",
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"
    ]
    public static let supportedExtensions = markdownExtensions
        .union(pdfExtensions)
        .union(textExtensions)
        .union(mediaExtensions)
        .union(nativePreviewExtensions)

    public static func kind(for url: URL) -> WorkspaceDocumentKind? {
        let kind = classification(for: url).kind
        return kind == .unsupported ? nil : kind
    }

    public static func classification(for url: URL) -> Classification {
        let fileExtension = url.pathExtension.lowercased()
        let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey, .localizedTypeDescriptionKey])
        let type = resourceValues?.contentType ?? UTType(filenameExtension: fileExtension)
        let contentTypeIdentifier = type?.identifier
        let localizedTypeDescription = resourceValues?.localizedTypeDescription ?? type?.localizedDescription

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

        if textExtensions.contains(fileExtension) {
            return Classification(
                kind: .text,
                contentTypeIdentifier: contentTypeIdentifier,
                localizedTypeDescription: localizedTypeDescription,
                capabilities: capabilities(for: .text)
            )
        }

        if mediaExtensions.contains(fileExtension) ||
            type?.conforms(to: .audio) == true ||
            type?.conforms(to: .movie) == true ||
            type?.conforms(to: .video) == true {
            return Classification(
                kind: .media,
                contentTypeIdentifier: contentTypeIdentifier,
                localizedTypeDescription: localizedTypeDescription,
                capabilities: capabilities(for: .media)
            )
        }

        if nativePreviewExtensions.contains(fileExtension) ||
            type?.conforms(to: .image) == true ||
            type?.conforms(to: .html) == true {
            return Classification(
                kind: .nativePreview,
                contentTypeIdentifier: contentTypeIdentifier,
                localizedTypeDescription: localizedTypeDescription,
                capabilities: capabilities(for: .nativePreview)
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
                usesQuickLookPreview: false
            )
        case .pdf:
            return WorkspaceDocumentCapabilities(
                canPreview: true,
                canEditText: false,
                canSearchText: false,
                canSearchPDF: true,
                canExportPDF: false,
                canShowOutline: false,
                usesQuickLookPreview: false
            )
        case .text:
            return WorkspaceDocumentCapabilities(
                canPreview: true,
                canEditText: true,
                canSearchText: true,
                canSearchPDF: false,
                canExportPDF: false,
                canShowOutline: false,
                usesQuickLookPreview: false
            )
        case .media:
            return WorkspaceDocumentCapabilities(
                canPreview: true,
                canEditText: false,
                canSearchText: false,
                canSearchPDF: false,
                canExportPDF: false,
                canShowOutline: false,
                usesQuickLookPreview: false
            )
        case .nativePreview:
            return WorkspaceDocumentCapabilities(
                canPreview: true,
                canEditText: false,
                canSearchText: false,
                canSearchPDF: false,
                canExportPDF: false,
                canShowOutline: false,
                usesQuickLookPreview: true
            )
        case .unsupported:
            return WorkspaceDocumentCapabilities(
                canPreview: false,
                canEditText: false,
                canSearchText: false,
                canSearchPDF: false,
                canExportPDF: false,
                canShowOutline: false,
                usesQuickLookPreview: false
            )
        }
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
