import Foundation
import UniformTypeIdentifiers

/// What a file holds, as its glyph says it in a tab, a sidebar row, Recents, Quick Open and Find in
/// Workspace (design.md §8.7). A text file is not a Markdown note: plain text, code, structured data
/// and tables each have their own glyph, and audio is not a video. Every name exists on macOS 14.
public enum WorkspaceFileGlyph: String, CaseIterable, Sendable {
    case markdown
    case pdf
    case plainText
    case code
    case data
    case table
    case image
    case video
    case audio
    /// A file Monknot lists but opens in its own app.
    case other

    /// Structured data and configuration, read as a document of keys and values.
    public static let dataExtensions: Set<String> = [
        "json", "jsonc", "yaml", "yml", "toml", "ini", "env", "plist", "conf", "cfg", "properties",
        "lock", "xml", "edn"
    ]
    public static let tableExtensions: Set<String> = ["csv", "tsv"]
    /// Prose with no markup Monknot renders.
    public static let plainTextExtensions: Set<String> = ["txt", "text", "log", "rst", "adoc", "org"]
    /// Extensionless files that hold prose by convention; the other conventional names (Makefile,
    /// Dockerfile, …) are code.
    public static let plainTextFilenames: Set<String> = [
        "license", "licence", "readme", "changelog", "authors", "contributors", "copying", "notice"
    ]

    /// The glyph for a document of `kind` at `path`, telling text files apart by their name.
    public init(kind: WorkspaceDocumentKind, path: String) {
        let name = (path as NSString).lastPathComponent.lowercased()
        // A dotfile's name is its type: ".env" is an env file.
        let pathExtension = name.hasPrefix(".") && !name.dropFirst().contains(".")
            ? String(name.dropFirst())
            : (name as NSString).pathExtension
        switch kind {
        case .markdown:
            self = .markdown
        case .pdf:
            self = .pdf
        case .image:
            self = .image
        case .media:
            let type = pathExtension.isEmpty ? nil : UTType(filenameExtension: pathExtension)
            self = type.map { $0.conforms(to: .audio) && !$0.conforms(to: .movie) } == true ? .audio : .video
        case .unsupported:
            self = .other
        case .text:
            self = Self.textGlyph(name: name, pathExtension: pathExtension)
        }
    }

    /// The glyph for the file at `path`, classified as the workspace scanner classifies it.
    public init(path: String) {
        let url = URL(fileURLWithPath: path)
        self.init(kind: WorkspaceDocumentSupport.classification(for: url).kind, path: path)
    }

    private static func textGlyph(name: String, pathExtension: String) -> WorkspaceFileGlyph {
        if dataExtensions.contains(pathExtension) { return .data }
        if tableExtensions.contains(pathExtension) { return .table }
        if plainTextExtensions.contains(pathExtension) { return .plainText }
        if pathExtension.isEmpty {
            return WorkspaceDocumentSupport.textFilenames.contains(name) && !plainTextFilenames.contains(name)
                ? .code
                : .plainText
        }
        // Source, scripts, markup and notebooks Monknot lists by name, and any type the system calls
        // source code; an extension nothing knows ("Release 1.2") is plain text.
        if WorkspaceDocumentSupport.textExtensions.contains(pathExtension)
            || WorkspaceDocumentSupport.htmlExtensions.contains(pathExtension)
            || pathExtension == "svg"
            || WorkspaceDocumentSupport.notebookExtensions.contains(pathExtension) {
            return .code
        }
        if let type = UTType(filenameExtension: pathExtension), !type.isDynamic,
           type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .html) {
            return .code
        }
        return .plainText
    }

    public var systemImage: String {
        switch self {
        case .markdown:
            return "doc.text"
        case .pdf:
            return "doc.richtext"
        case .plainText:
            return "doc.plaintext"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .data:
            return "curlybraces"
        case .table:
            return "tablecells"
        case .image:
            return "photo"
        case .video:
            return "play.rectangle"
        case .audio:
            return "waveform"
        case .other:
            return "doc"
        }
    }
}

extension WorkspaceDocumentKind {
    /// The kind's glyph when nothing but the kind is known; a document's own glyph tells its text
    /// files apart (`WorkspaceDocument.fileGlyph`).
    public var systemImage: String {
        WorkspaceFileGlyph(kind: self, path: "").systemImage
    }
}

extension WorkspaceDocument {
    public var fileGlyph: WorkspaceFileGlyph {
        WorkspaceFileGlyph(kind: kind, path: id)
    }
}

extension WorkspaceTabItem {
    public var fileGlyph: WorkspaceFileGlyph {
        WorkspaceFileGlyph(kind: kind, path: documentID)
    }
}

extension EditorMode {
    /// SF Symbol for the markdown source / preview toggle.
    public var systemImage: String {
        switch self {
        case .source:
            return "text.alignleft"
        case .preview:
            return "eye"
        }
    }
}
