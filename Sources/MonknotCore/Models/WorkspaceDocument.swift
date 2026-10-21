import Foundation
import UniformTypeIdentifiers

public enum WorkspaceDocumentKind: String, Codable, Sendable {
    case markdown
    case pdf
    case text
    case image
    case media
    case unsupported

    /// PDFs, and images shown on a PDF page, open in the PDF viewer and take its markup.
    public var opensInPDFViewer: Bool {
        self == .pdf || self == .image
    }

    /// A kind saved by an older build that no longer exists (open tabs, Recents) reads as a file
    /// that opens in its own app, so the rest of what was saved still loads.
    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unsupported
    }
}

public struct WorkspaceDocumentCapabilities: Codable, Hashable, Sendable {
    public let canPreview: Bool
    public let canEditText: Bool
    public let canSearchText: Bool
    public let canSearchPDF: Bool
    public let canExportPDF: Bool
    public let canShowOutline: Bool
    public let canPreviewHTML: Bool
    /// A Jupyter notebook: its JSON is the source, and Preview shows its cells and outputs.
    public let canPreviewNotebook: Bool

    public init(
        canPreview: Bool,
        canEditText: Bool,
        canSearchText: Bool,
        canSearchPDF: Bool,
        canExportPDF: Bool,
        canShowOutline: Bool,
        canPreviewHTML: Bool = false,
        canPreviewNotebook: Bool = false
    ) {
        self.canPreview = canPreview
        self.canEditText = canEditText
        self.canSearchText = canSearchText
        self.canSearchPDF = canSearchPDF
        self.canExportPDF = canExportPDF
        self.canShowOutline = canShowOutline
        self.canPreviewHTML = canPreviewHTML
        self.canPreviewNotebook = canPreviewNotebook
    }

    private enum CodingKeys: String, CodingKey {
        case canPreview, canEditText, canSearchText, canSearchPDF, canExportPDF, canShowOutline
        case canPreviewHTML, canPreviewNotebook
    }

    /// Reads capabilities saved before notebooks had a preview.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            canPreview: try container.decode(Bool.self, forKey: .canPreview),
            canEditText: try container.decode(Bool.self, forKey: .canEditText),
            canSearchText: try container.decode(Bool.self, forKey: .canSearchText),
            canSearchPDF: try container.decode(Bool.self, forKey: .canSearchPDF),
            canExportPDF: try container.decode(Bool.self, forKey: .canExportPDF),
            canShowOutline: try container.decode(Bool.self, forKey: .canShowOutline),
            canPreviewHTML: try container.decodeIfPresent(Bool.self, forKey: .canPreviewHTML) ?? false,
            canPreviewNotebook: try container.decodeIfPresent(Bool.self, forKey: .canPreviewNotebook) ?? false
        )
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

    /// Markdown notes, HTML pages and notebooks have a rendered preview beside their source
    /// (Preview mode and split view); other documents show only their source or their own viewer.
    public var hasPreviewMode: Bool {
        kind == .markdown || capabilities.canPreviewHTML || capabilities.canPreviewNotebook
    }

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
    public enum RelativePathValidationError: Error, Equatable, LocalizedError, Sendable {
        case workspaceUnavailable
        case itemUnavailable
        case workspaceRoot
        case outsideWorkspace

        public var errorDescription: String? {
            switch self {
            case .workspaceUnavailable:
                return "The workspace folder is no longer available."
            case .itemUnavailable:
                return "The item is no longer available."
            case .workspaceRoot:
                return "The workspace root does not have a relative path."
            case .outsideWorkspace:
                return "The item is outside the current workspace."
            }
        }
    }

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
    public static let notebookExtensions: Set<String> = ["ipynb"]
    public static let textExtensions: Set<String> = [
        "txt", "text", "log",
        "mmd", "mermaid", "mdx",
        "swift", "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "java", "kt",
        "c", "h", "cpp", "cxx", "cc", "hpp", "m", "mm", "php",
        "sh", "bash", "zsh", "fish",
        "sql", "graphql", "gql", "proto", "dockerfile",
        "css", "scss", "sass", "less",
        "json", "jsonc", "yaml", "yml", "xml", "csv", "tsv", "toml", "ini", "env", "plist",
        // Source and text formats the system does not declare.
        "lua", "vue", "svelte", "astro", "dart", "scala", "kts", "groovy", "gradle", "r", "rmd", "qmd",
        "jl", "hs", "ex", "exs", "erl", "clj", "cljs", "edn", "elm", "ml", "mli", "fs", "fsx", "nim",
        "zig", "v", "sol", "tf", "hcl", "nix", "cmake", "mk", "bat", "ps1", "rst", "adoc", "org",
        "tex", "bib", "sty", "cls", "lock", "conf", "cfg", "properties"
    ]
    /// Raster images ImageIO decodes. SVG stays a text document: its source is the file.
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp", "ico", "avif"
    ]
    /// Video and audio AVFoundation plays. They are listed by extension alone: a file is first
    /// read when it opens in the player, never while the workspace is scanned or searched.
    public static let mediaExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mpg", "mpeg",
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"
    ]
    /// Extensionless files that hold text by convention, matched case-insensitively.
    public static let textFilenames: Set<String> = [
        "dockerfile", "makefile", "procfile", "gemfile", "rakefile", "justfile",
        "license", "licence", "readme", "changelog", "authors", "contributors", "copying", "notice"
    ]
    /// Formats listed but opened in their own app, never as text: binary formats common in
    /// projects that the system does not declare, and RTF, whose text is markup.
    public static let ownAppExtensions: Set<String> = [
        "sqlite", "sqlite3", "db", "woff", "woff2", "wasm", "mkv", "ogg", "so", "rlib", "rmeta",
        "pkl", "npy", "npz", "parquet", "h5", "pt", "pth", "onnx", "safetensors", "gguf", "ckpt",
        "rtf"
    ]

    /// Whether the text after a name's last dot is the extension of a file type Monknot or the
    /// system knows, so "notes.lua" and "Clip.mov" have one and "Release 1.2", "Release v1.0-beta"
    /// and "John.Smith" do not: New File gives those `.md`, and Rename keeps the file's own.
    public static func isKnownFileExtension(_ pathExtension: String) -> Bool {
        let lowercased = pathExtension.lowercased()
        guard !lowercased.isEmpty else { return false }
        if markdownExtensions.contains(lowercased) || pdfExtensions.contains(lowercased)
            || htmlExtensions.contains(lowercased) || notebookExtensions.contains(lowercased)
            || textExtensions.contains(lowercased) || imageExtensions.contains(lowercased)
            || mediaExtensions.contains(lowercased) || ownAppExtensions.contains(lowercased) {
            return true
        }
        return UTType(filenameExtension: lowercased).map { !$0.isDynamic } ?? false
    }

    /// Whether a folder with this name is a package, such as `Release.app` or `Notes.rtfd`, which
    /// Finder shows as a single item.
    public static func isPackageName(_ name: String) -> Bool {
        let pathExtension = (name as NSString).pathExtension
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension, conformingTo: .package)
        else { return false }
        return !type.isDynamic
    }

    /// The longest file or folder name macOS accepts, measured by `fileNameLength(_:)`.
    public static let maximumFileNameLength = 255

    /// The length macOS limits a file or folder name by: its UTF-16 code units once decomposed,
    /// so "é" counts 2 and an emoji 2.
    public static func fileNameLength(_ name: String) -> Int {
        name.decomposedStringWithCanonicalMapping.utf16.count
    }

    /// `name` in `directoryURL`, or when that is taken, the first free "name copy", "name copy 2", ….
    /// A file or package keeps its extension last ("photo copy.png"); a folder's name is used whole,
    /// so "v1.2" becomes "v1.2 copy". As in Finder, a name too long to take the suffix is shortened
    /// at a character boundary to fit `maximumFileNameLength`. A name holding a path in `reservedPaths`
    /// (a removed note whose unsaved text is still open), or that path itself, counts as taken.
    public static func availableCopyURL(
        named name: String,
        isDirectory: Bool,
        in directoryURL: URL,
        reservedPaths: Set<String> = [],
        fileManager: FileManager = .default
    ) -> URL {
        func isTaken(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            return fileManager.fileExists(atPath: path)
                || reservedPaths.contains { isPath($0, containedIn: path) }
        }
        var candidate = directoryURL.appendingPathComponent(name)
        guard isTaken(candidate) else { return candidate }

        let splitsExtension = !isDirectory || isPackageName(name)
        let pathExtension = splitsExtension ? (name as NSString).pathExtension : ""
        let baseName = pathExtension.isEmpty ? name : (name as NSString).deletingPathExtension
        var index = 1
        repeat {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let ending = pathExtension.isEmpty ? suffix : "\(suffix).\(pathExtension)"
            candidate = directoryURL.appendingPathComponent(fittedName(baseName, ending: ending))
            index += 1
        } while isTaken(candidate)
        return candidate
    }

    /// `baseName` followed by `ending`, with as many trailing characters of `baseName` dropped as
    /// the result needs to fit `maximumFileNameLength`.
    private static func fittedName(_ baseName: String, ending: String) -> String {
        let budget = maximumFileNameLength - fileNameLength(ending)
        guard fileNameLength(baseName) > budget else { return baseName + ending }
        var base = Substring(baseName)
        while !base.isEmpty, fileNameLength(String(base)) > budget || base.last?.isWhitespace == true {
            base.removeLast()
        }
        return base + ending
    }

    /// Whether `url` is `directoryURL` or inside it, comparing standardized paths.
    public static func isURL(_ url: URL, containedIn directoryURL: URL) -> Bool {
        isPath(url.standardizedFileURL.path, containedIn: directoryURL.standardizedFileURL.path)
    }

    /// Whether `path` is `directoryPath` or inside it. Both are standardized paths, such as
    /// document and sidebar node IDs.
    public static func isPath(_ path: String, containedIn directoryPath: String) -> Bool {
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return path == directoryPath || path.hasPrefix(prefix)
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

        if imageExtensions.contains(fileExtension) {
            return Classification(
                kind: .image,
                contentTypeIdentifier: contentTypeIdentifier,
                localizedTypeDescription: localizedTypeDescription,
                capabilities: capabilities(for: .image)
            )
        }

        if mediaExtensions.contains(fileExtension) {
            return Classification(
                kind: .media,
                contentTypeIdentifier: contentTypeIdentifier,
                localizedTypeDescription: localizedTypeDescription,
                capabilities: capabilities(for: .media)
            )
        }

        if notebookExtensions.contains(fileExtension) {
            return Classification(
                kind: .text,
                contentTypeIdentifier: contentTypeIdentifier,
                localizedTypeDescription: localizedTypeDescription,
                capabilities: notebookCapabilities()
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

        // A type the system does not know (most source formats, "LICENSE-MIT") opens as text; the
        // editor shows why when the bytes are not UTF-8 text (`WorkspaceTextFileGuard`).
        let isUnknownType = type == nil || type?.isDynamic == true
        if !ownAppExtensions.contains(fileExtension) && (
            type?.conforms(to: .text) == true ||
            type?.conforms(to: .plainText) == true ||
            type?.conforms(to: .sourceCode) == true ||
            isUnknownType
        ) {
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
        case .image:
            return WorkspaceDocumentCapabilities(
                canPreview: true,
                canEditText: false,
                canSearchText: false,
                canSearchPDF: false,
                canExportPDF: false,
                canShowOutline: false,
                canPreviewHTML: false
            )
        case .media:
            return WorkspaceDocumentCapabilities(
                canPreview: true,
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

    private static func notebookCapabilities() -> WorkspaceDocumentCapabilities {
        WorkspaceDocumentCapabilities(
            canPreview: true,
            canEditText: true,
            canSearchText: true,
            canSearchPDF: false,
            canExportPDF: false,
            canShowOutline: false,
            canPreviewNotebook: true
        )
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

    /// Returns a current, workspace-contained POSIX path for a file or folder.
    /// Unlike `relativePath(for:in:)`, this rejects stale and out-of-workspace URLs.
    public static func validatedRelativePath(
        for url: URL,
        in rootURL: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        let standardizedRootURL = rootURL.standardizedFileURL
        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: standardizedRootURL.path,
            isDirectory: &rootIsDirectory
        ), rootIsDirectory.boolValue else {
            throw RelativePathValidationError.workspaceUnavailable
        }

        let standardizedURL = url.standardizedFileURL
        guard fileManager.fileExists(atPath: standardizedURL.path) else {
            throw RelativePathValidationError.itemUnavailable
        }

        let itemValues: URLResourceValues
        do {
            itemValues = try standardizedURL.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            throw RelativePathValidationError.itemUnavailable
        }
        guard itemValues.isSymbolicLink != true,
              itemValues.isDirectory == true || itemValues.isRegularFile == true
        else {
            throw RelativePathValidationError.itemUnavailable
        }

        let canonicalRootURL = standardizedRootURL.resolvingSymlinksInPath()
        let canonicalURL = standardizedURL.resolvingSymlinksInPath()
        let rootComponents = canonicalRootURL.pathComponents
        let itemComponents = canonicalURL.pathComponents

        guard itemComponents != rootComponents else {
            throw RelativePathValidationError.workspaceRoot
        }
        guard itemComponents.count > rootComponents.count,
              Array(itemComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw RelativePathValidationError.outsideWorkspace
        }

        return itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
