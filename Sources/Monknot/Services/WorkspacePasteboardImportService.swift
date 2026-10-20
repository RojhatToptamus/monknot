import AppKit
import Foundation
import MonknotCore
import UniformTypeIdentifiers

struct WorkspacePasteboardImportItem: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case fileURL(URL)
        case pngImageData(Data, suggestedName: String)
        case capturedMarkdown(String, suggestedName: String)
    }

    let payload: Payload

    static func fileURL(_ url: URL) -> WorkspacePasteboardImportItem {
        WorkspacePasteboardImportItem(payload: .fileURL(url))
    }

    static func pngImageData(_ data: Data, suggestedName: String = "Pasted Image.png") -> WorkspacePasteboardImportItem {
        WorkspacePasteboardImportItem(payload: .pngImageData(data, suggestedName: suggestedName))
    }

    static func capturedMarkdown(_ markdown: String, suggestedName: String = "Clipboard.md") -> WorkspacePasteboardImportItem {
        WorkspacePasteboardImportItem(payload: .capturedMarkdown(markdown, suggestedName: suggestedName))
    }

    var prefersSelectionAfterImport: Bool {
        if case .capturedMarkdown = payload {
            return true
        }
        return false
    }
}

enum WorkspacePasteboardImportService {
    static func importItems(from pasteboard: NSPasteboard) throws -> [WorkspacePasteboardImportItem] {
        let fileURLObjects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        let fileURLs = fileURLObjects.compactMap { object -> URL? in
            if let url = object as? URL {
                return url
            }
            if let url = object as? NSURL {
                return url as URL
            }
            return nil
        }

        if !fileURLs.isEmpty {
            return fileURLs.map(WorkspacePasteboardImportItem.fileURL)
        }

        let imageObjects = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) ?? []
        let imageItems: [WorkspacePasteboardImportItem] = try imageObjects.enumerated().compactMap { index, object in
            guard let image = object as? NSImage else { return nil }
            guard let pngData = pngData(for: image) else {
                throw WorkspacePasteboardImportError.couldNotEncodeImage
            }

            let suggestedName = imageObjects.count == 1
                ? "Pasted Image.png"
                : "Pasted Image \(index + 1).png"
            return .pngImageData(pngData, suggestedName: suggestedName)
        }
        if !imageItems.isEmpty {
            return imageItems
        }

        if let urlString = pasteboard.string(forType: .URL),
           let item = capturedTextItem(from: urlString, isURL: true) {
            return [item]
        }

        if let text = pasteboard.string(forType: .string) ?? plainText(fromHTMLOn: pasteboard),
           let item = capturedTextItem(from: text, isURL: false) {
            return [item]
        }

        return []
    }

    /// The text of HTML that an app put on the pasteboard without a plain-text version.
    private static func plainText(fromHTMLOn pasteboard: NSPasteboard) -> String? {
        guard let data = pasteboard.data(forType: .html) else { return nil }
        return plainText(fromHTML: String(decoding: data, as: UTF8.self))
    }

    /// The text of `html`, keeping its paragraphs, line breaks and list items. Tags are dropped
    /// and character references decoded; nothing the HTML refers to is loaded, and scripts, styles
    /// and the document head are left out.
    static func plainText(fromHTML html: String) -> String {
        var text = ""
        var skippedElement: String?
        var index = html.startIndex

        while index < html.endIndex {
            guard html[index] == "<" else {
                let end = html[index...].firstIndex(of: "<") ?? html.endIndex
                if skippedElement == nil {
                    text += decodingCharacterReferences(in: collapsingWhitespace(html[index..<end]))
                }
                index = end
                continue
            }
            if html[index...].hasPrefix("<!--") {
                index = html[index...].range(of: "-->")?.upperBound ?? html.endIndex
                continue
            }
            // A `<` that starts no tag, as in "a < b", is text.
            let next = html.index(after: index)
            guard next < html.endIndex, html[next].isLetter || html[next] == "/" || html[next] == "!" else {
                if skippedElement == nil { text += "<" }
                index = next
                continue
            }

            let tagEnd = endOfTag(in: html, from: index)
            let tag = html[html.index(after: index)..<tagEnd]
            index = tagEnd < html.endIndex ? html.index(after: tagEnd) : html.endIndex
            let isClosing = tag.hasPrefix("/")
            let name = tag.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()

            if let skipped = skippedElement {
                if isClosing, name == skipped {
                    skippedElement = nil
                }
                continue
            }
            if !isClosing, htmlSkippedElements.contains(name), !tag.hasSuffix("/") {
                skippedElement = name
            } else if name == "br" {
                text += "\n"
            } else if name == "li", !isClosing {
                text += "\n- "
            } else if name == "tr" {
                text += "\n"
            } else if name == "td" || name == "th" {
                text += " "
            } else if htmlBlockElements.contains(name) {
                text += "\n\n"
            }
        }

        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, lines.last?.isEmpty != false { continue }
            lines.append(Substring(trimmed))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let htmlSkippedElements: Set<String> = ["head", "script", "style", "template", "title"]
    private static let htmlBlockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "figcaption", "figure",
        "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "nav", "ol", "p", "pre",
        "section", "table", "ul",
    ]

    /// The index of the `>` that ends the tag opening at `start`, past any quoted attribute value.
    private static func endOfTag(in html: String, from start: String.Index) -> String.Index {
        var quote: Character?
        var index = html.index(after: start)
        while index < html.endIndex {
            let character = html[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return html.endIndex
    }

    /// HTML text with each run of white space as one space, as a browser shows it.
    private static func collapsingWhitespace(_ text: Substring) -> String {
        var result = ""
        var lastWasSpace = false
        for character in text {
            if character.isWhitespace {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        return result
    }

    /// `text` with its numeric and common named character references decoded; any other `&` stays.
    private static func decodingCharacterReferences(in text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";"),
                  let decoded = characterReference(text[text.index(after: index)..<semicolon])
            else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            result.append(decoded)
            index = text.index(after: semicolon)
        }
        return result
    }

    private static func characterReference(_ name: Substring) -> Character? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits)
            guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
            return Character(scalar)
        }
        return htmlNamedCharacters[String(name)]
    }

    private static let htmlNamedCharacters: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "bull": "\u{2022}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "middot": "\u{00B7}",
    ]

    static func importItems(_ items: [WorkspacePasteboardImportItem], into directoryURL: URL) throws -> [URL] {
        try validateDirectory(directoryURL)

        var importedURLs: [URL] = []
        for item in items {
            try Task.checkCancellation()

            switch item.payload {
            case .fileURL(let sourceURL):
                importedURLs.append(try copyFile(at: sourceURL, into: directoryURL))
            case .pngImageData(let data, let suggestedName):
                let destinationURL = WorkspaceDocumentSupport.availableCopyURL(
                    named: sanitizedFileName(suggestedName, fallback: "Pasted Image.png"),
                    isDirectory: false,
                    in: directoryURL
                )
                try data.write(to: destinationURL, options: .atomic)
                importedURLs.append(destinationURL)
            case .capturedMarkdown(let markdown, let suggestedName):
                let inboxURL = directoryURL.appendingPathComponent("inbox", isDirectory: true)
                try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
                let destinationURL = WorkspaceDocumentSupport.availableCopyURL(
                    named: sanitizedFileName(suggestedName, fallback: "Clipboard.md"),
                    isDirectory: false,
                    in: inboxURL
                )
                try markdown.write(to: destinationURL, atomically: true, encoding: .utf8)
                importedURLs.append(destinationURL)
            }
        }

        return importedURLs
    }

    private static func copyFile(at sourceURL: URL, into directoryURL: URL) throws -> URL {
        let sourceURL = sourceURL.standardizedFileURL
        let resourceValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])

        guard resourceValues.isDirectory == true || resourceValues.isRegularFile == true else {
            throw WorkspacePasteboardImportError.unsupportedSource(sourceURL.lastPathComponent)
        }

        let isDirectory = resourceValues.isDirectory == true
        if isDirectory, WorkspaceDocumentSupport.isURL(directoryURL, containedIn: sourceURL) {
            throw WorkspacePasteboardImportError.sourceContainsDestination(sourceURL.lastPathComponent)
        }

        let fileName = sanitizedFileName(sourceURL.lastPathComponent, fallback: "Pasted File")
        let destinationURL = WorkspaceDocumentSupport.availableCopyURL(
            named: fileName,
            isDirectory: isDirectory,
            in: directoryURL
        )
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private static func validateDirectory(_ url: URL) throws {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspacePasteboardImportError.invalidDestination(url.lastPathComponent)
        }
    }

    fileprivate static func sanitizedFileName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "/:")) == nil
        else {
            return fallback
        }

        return trimmed
    }

    static func capturedTextItem(
        from rawText: String,
        isURL: Bool,
        titleOverride: String? = nil
    ) -> WorkspacePasteboardImportItem? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let capturedURL = captureURL(from: trimmed, explicitURLType: isURL)
        let title = captureTitle(for: trimmed, url: capturedURL, override: titleOverride)
        let timestamp = captureTimestamp()
        let fileName = sanitizedFileName("\(timestamp) \(fileNameTitle(title)).md", fallback: "\(timestamp) Clipboard.md")
        let markdown: String

        if let url = capturedURL {
            let sourceURL = canonicalSourceURL(url)
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var metadataLines = [
                "Source: \(sourceURL.absoluteString)"
            ]
            if let host = url.host, !host.isEmpty {
                metadataLines.append("Host: \(host)")
            }
            if !path.isEmpty {
                metadataLines.append("Path: /\(path)")
            }

            markdown = """
            # \(title)

            \(metadataLines.joined(separator: "\n"))

            """
        } else {
            markdown = """
            # \(title)

            \(trimmed)

            """
        }

        return .capturedMarkdown(markdown, suggestedName: fileName)
    }

    /// `title` as part of a file name, which cannot hold a colon or a slash: each becomes a dash,
    /// so "Meeting: Q3" names "Meeting - Q3.md" and "A/B" names "A-B.md".
    private static func fileNameTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: ": ", with: " - ")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    private static func captureURL(from text: String, explicitURLType: Bool) -> URL? {
        guard !text.contains(where: \.isNewline), let url = URL(string: text) else {
            return nil
        }

        let allowedSchemes: Set<String> = ["http", "https"]
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme), url.host?.isEmpty == false else {
            return explicitURLType ? url : nil
        }

        return url
    }

    private static func captureTitle(for text: String, url: URL?, override: String?) -> String {
        let overrideTitle = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !overrideTitle.isEmpty {
            return String(overrideTitle.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let url {
            if let title = titleFromURLPath(url) {
                return title
            }
            if let host = url.host, !host.isEmpty {
                return host
            }
        }

        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Clipboard"
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(trimmed.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? "Clipboard" : limited
    }

    private static func titleFromURLPath(_ url: URL) -> String? {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }

        let lastComponent = path
            .split(separator: "/")
            .last
            .map(String.init)?
            .removingPercentEncoding ?? ""
        let withoutExtension = URL(fileURLWithPath: lastComponent).deletingPathExtension().lastPathComponent
        let words = withoutExtension
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                let lower = word.lowercased()
                guard let first = lower.first else { return "" }
                return String(first).uppercased() + lower.dropFirst()
            }

        let title = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 3 else { return nil }
        return String(title.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalSourceURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = nil
        return components.url ?? url
    }

    private static func captureTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: Date())
    }

    static func pngData(for image: NSImage) -> Data? {
        if let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            return pngData
        }

        for representation in image.representations {
            if let bitmap = representation as? NSBitmapImageRep,
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                return pngData
            }
        }

        return nil
    }

    /// Whether `importItems(from:)` may find something on `pasteboard`, from the kinds of data it
    /// holds and without reading them.
    static func canImportItems(from pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self, NSImage.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: [.URL, .string, .rtf, .html]) != nil
    }
}

struct MarkdownImageAsset: Equatable, Sendable {
    let fileURL: URL
    let relativePath: String

    var markdown: String {
        "![Pasted image](\(relativePath))"
    }
}

struct MarkdownFileDropPlan: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        let sourceURL: URL
        let isExternal: Bool
        let isImage: Bool
    }

    let workspaceURL: URL
    let markdownDocumentURL: URL
    let items: [Item]

    var requiresImportConfirmation: Bool {
        items.contains(where: \.isExternal)
    }

    var externalItemNames: [String] {
        items.filter(\.isExternal).map(\.sourceURL.lastPathComponent)
    }
}

struct MarkdownFileDropAsset: Equatable, Sendable {
    let fileURL: URL
    let relativePath: String
    let displayName: String
    let isImage: Bool
    let wasImported: Bool

    var markdown: String {
        let label = MarkdownImageAssetService.escapeMarkdownLabel(displayName)
        let destination = MarkdownImageAssetService.percentEncodedMarkdownPath(relativePath)
        return isImage ? "![\(label)](\(destination))" : "[\(label)](\(destination))"
    }
}

struct MarkdownFileDropResult: Equatable, Sendable {
    let assets: [MarkdownFileDropAsset]

    var importedAssets: [MarkdownFileDropAsset] {
        assets.filter(\.wasImported)
    }

    var markdown: String {
        assets.map(\.markdown).joined(separator: "\n")
    }
}

enum MarkdownImageAssetService {
    private static let maximumDropItemCount = 32
    private static let maximumExternalFileBytes = 64 * 1_024 * 1_024

    static func savePNG(
        _ data: Data,
        workspaceURL: URL,
        markdownDocumentURL: URL
    ) throws -> MarkdownImageAsset {
        guard !data.isEmpty else {
            throw MarkdownImageAssetError.emptyImage
        }

        let root = canonical(workspaceURL)
        let documentURL = canonical(markdownDocumentURL)
        guard isContained(documentURL, in: root) else {
            throw MarkdownImageAssetError.outsideWorkspace
        }

        let canonicalAssets = try validatedAssetsDirectory(workspaceURL: workspaceURL, root: root)

        let fileName = "pasted-image-\(shortTimestamp())-\(UUID().uuidString.prefix(8).lowercased()).png"
        let destinationURL = canonicalAssets.appendingPathComponent(fileName, isDirectory: false)
        guard isContained(destinationURL, in: root) else {
            throw MarkdownImageAssetError.outsideWorkspace
        }

        let temporaryURL = canonicalAssets.appendingPathComponent(
            ".monknot-paste-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .atomic)
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return MarkdownImageAsset(
            fileURL: destinationURL,
            relativePath: relativePath(
                from: markdownDocumentURL.deletingLastPathComponent(),
                to: destinationURL
            )
        )
    }

    static func planFileDrop(
        _ urls: [URL],
        workspaceURL: URL,
        markdownDocumentURL: URL
    ) throws -> MarkdownFileDropPlan {
        guard !urls.isEmpty, urls.count <= maximumDropItemCount else {
            throw MarkdownImageAssetError.invalidDropCount(maximumDropItemCount)
        }

        let root = canonical(workspaceURL)
        let documentURL = canonical(markdownDocumentURL)
        guard isContained(documentURL, in: root) else {
            throw MarkdownImageAssetError.outsideWorkspace
        }

        var seenPaths = Set<String>()
        var items: [MarkdownFileDropPlan.Item] = []
        for originalURL in urls {
            try Task.checkCancellation()
            let sourceURL = originalURL.standardizedFileURL
            let values = try sourceURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentTypeKey,
            ])
            guard values.isRegularFile == true,
                  values.isDirectory != true,
                  values.isSymbolicLink != true
            else {
                throw MarkdownImageAssetError.unsupportedDroppedFile(sourceURL.lastPathComponent)
            }

            let resolvedURL = canonical(sourceURL)
            guard seenPaths.insert(resolvedURL.path).inserted else { continue }
            let isExternal = !isContained(resolvedURL, in: root)
            let isImage = values.contentType?.conforms(to: .image) == true ||
                UTType(filenameExtension: sourceURL.pathExtension)?.conforms(to: .image) == true
            guard !isExternal || isImage || WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(sourceURL) else {
                throw MarkdownImageAssetError.unsupportedDroppedFile(sourceURL.lastPathComponent)
            }
            if isExternal, (values.fileSize ?? 0) > maximumExternalFileBytes {
                throw MarkdownImageAssetError.droppedFileTooLarge(sourceURL.lastPathComponent)
            }
            items.append(MarkdownFileDropPlan.Item(
                sourceURL: sourceURL,
                isExternal: isExternal,
                isImage: isImage
            ))
        }

        guard !items.isEmpty else {
            throw MarkdownImageAssetError.noDroppedFiles
        }
        return MarkdownFileDropPlan(
            workspaceURL: root,
            markdownDocumentURL: documentURL,
            items: items
        )
    }

    static func importFileDrop(_ originalPlan: MarkdownFileDropPlan) throws -> MarkdownFileDropResult {
        let plan = try planFileDrop(
            originalPlan.items.map(\.sourceURL),
            workspaceURL: originalPlan.workspaceURL,
            markdownDocumentURL: originalPlan.markdownDocumentURL
        )
        guard plan == originalPlan else {
            throw MarkdownImageAssetError.droppedFilesChanged
        }

        let documentDirectory = plan.markdownDocumentURL.deletingLastPathComponent()
        var completed: [MarkdownFileDropAsset] = []
        do {
            for item in plan.items {
                try Task.checkCancellation()
                if item.isExternal {
                    let asset = try importExternalDropItem(
                        item,
                        workspaceURL: plan.workspaceURL,
                        markdownDocumentURL: plan.markdownDocumentURL
                    )
                    completed.append(asset)
                } else {
                    let relativePath = relativePath(from: documentDirectory, to: canonical(item.sourceURL))
                    completed.append(MarkdownFileDropAsset(
                        fileURL: canonical(item.sourceURL),
                        relativePath: relativePath,
                        displayName: displayName(for: item.sourceURL),
                        isImage: item.isImage,
                        wasImported: false
                    ))
                }
            }
            try Task.checkCancellation()
            return MarkdownFileDropResult(assets: completed)
        } catch {
            removeUncommittedAssets(completed, workspaceURL: plan.workspaceURL)
            throw error
        }
    }

    static func removeUncommittedAsset(_ asset: MarkdownImageAsset, workspaceURL: URL) {
        let root = canonical(workspaceURL)
        let fileURL = canonical(asset.fileURL)
        guard isContained(fileURL, in: root),
              fileURL.deletingLastPathComponent().lastPathComponent == "assets"
        else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func removeUncommittedAssets(_ assets: [MarkdownFileDropAsset], workspaceURL: URL) {
        let root = canonical(workspaceURL)
        for asset in assets where asset.wasImported {
            let fileURL = canonical(asset.fileURL)
            guard isContained(fileURL, in: root),
                  fileURL.deletingLastPathComponent().lastPathComponent == "assets"
            else { continue }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    static func escapeMarkdownLabel(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["[", "]", "(", ")"] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return escaped
    }

    static func percentEncodedMarkdownPath(_ path: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return path.precomposedStringWithCanonicalMapping
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static func importExternalDropItem(
        _ item: MarkdownFileDropPlan.Item,
        workspaceURL: URL,
        markdownDocumentURL: URL
    ) throws -> MarkdownFileDropAsset {
        let root = canonical(workspaceURL)
        let assetsURL = try validatedAssetsDirectory(workspaceURL: workspaceURL, root: root)
        let originalName = WorkspacePasteboardImportService.sanitizedFileName(
            item.sourceURL.lastPathComponent,
            fallback: item.isImage ? "Dropped Image.png" : "Dropped File"
        )
        let convertsToPNG = item.isImage && !keepsOriginalImageFormat(item.sourceURL)
        let proposedName: String
        if convertsToPNG {
            let baseName = URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
            proposedName = "\(baseName).png"
        } else {
            proposedName = originalName
        }
        let destinationURL = WorkspaceDocumentSupport.availableCopyURL(
            named: proposedName,
            isDirectory: false,
            in: assetsURL
        )
        guard isContained(destinationURL, in: root) else {
            throw MarkdownImageAssetError.outsideWorkspace
        }

        let temporaryURL = assetsURL.appendingPathComponent(".monknot-drop-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        if item.isImage {
            // Loading it also rejects a file that is not an image at all.
            guard let image = NSImage(contentsOf: item.sourceURL), image.isValid else {
                throw MarkdownImageAssetError.couldNotReadDroppedImage(item.sourceURL.lastPathComponent)
            }
            if convertsToPNG {
                guard let data = WorkspacePasteboardImportService.pngData(for: image) else {
                    throw MarkdownImageAssetError.couldNotReadDroppedImage(item.sourceURL.lastPathComponent)
                }
                try data.write(to: temporaryURL, options: .atomic)
            } else {
                try FileManager.default.copyItem(at: item.sourceURL, to: temporaryURL)
            }
        } else {
            try FileManager.default.copyItem(at: item.sourceURL, to: temporaryURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)

        return MarkdownFileDropAsset(
            fileURL: destinationURL,
            relativePath: relativePath(
                from: markdownDocumentURL.deletingLastPathComponent(),
                to: destinationURL
            ),
            displayName: displayName(for: destinationURL),
            isImage: item.isImage,
            wasImported: true
        )
    }

    /// Formats every browser shows are copied untouched, so a photo keeps its size and a GIF its
    /// animation. Other images (HEIC, TIFF, BMP, …) become PNG so notes stay portable.
    static func keepsOriginalImageFormat(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return [UTType.png, .jpeg, .gif, .webP, .svg].contains { type.conforms(to: $0) }
    }

    private static func validatedAssetsDirectory(workspaceURL: URL, root: URL) throws -> URL {
        let assetsURL = workspaceURL.appendingPathComponent("assets", isDirectory: true)
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: assetsURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw MarkdownImageAssetError.assetsIsNotDirectory
            }
        } else {
            try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: assetsURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { throw MarkdownImageAssetError.assetsIsNotDirectory }
        }

        let canonicalAssets = canonical(assetsURL)
        let expectedAssets = root.appendingPathComponent("assets", isDirectory: true).standardizedFileURL
        guard canonicalAssets == expectedAssets, isContained(canonicalAssets, in: root) else {
            throw MarkdownImageAssetError.outsideWorkspace
        }
        return canonicalAssets
    }

    private static func displayName(for url: URL) -> String {
        let withoutExtension = url.deletingPathExtension().lastPathComponent
        return (withoutExtension.isEmpty ? url.lastPathComponent : withoutExtension)
            .precomposedStringWithCanonicalMapping
    }

    private static func relativePath(from sourceDirectory: URL, to target: URL) -> String {
        let sourceComponents = sourceDirectory.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var commonCount = 0
        while commonCount < min(sourceComponents.count, targetComponents.count),
              sourceComponents[commonCount] == targetComponents[commonCount] {
            commonCount += 1
        }
        let upward = Array(repeating: "..", count: sourceComponents.count - commonCount)
        let downward = Array(targetComponents.dropFirst(commonCount))
        return (upward + downward).joined(separator: "/")
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func shortTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private enum MarkdownImageAssetError: LocalizedError {
    case emptyImage
    case outsideWorkspace
    case assetsIsNotDirectory
    case invalidDropCount(Int)
    case noDroppedFiles
    case unsupportedDroppedFile(String)
    case droppedFileTooLarge(String)
    case droppedFilesChanged
    case couldNotReadDroppedImage(String)

    var errorDescription: String? {
        switch self {
        case .emptyImage:
            return "The pasted image is empty."
        case .outsideWorkspace:
            return "Images can only be saved inside the current workspace."
        case .assetsIsNotDirectory:
            return "The workspace assets item is not a folder."
        case .invalidDropCount(let maximum):
            return "Insert between 1 and \(maximum) files at a time."
        case .noDroppedFiles:
            return "There are no new files to insert."
        case .unsupportedDroppedFile(let name):
            return "\(name) is not a supported file. Folders, aliases, and binary files cannot be inserted."
        case .droppedFileTooLarge(let name):
            return "\(name) is too large to import."
        case .droppedFilesChanged:
            return "The files changed before they could be imported."
        case .couldNotReadDroppedImage(let name):
            return "\(name) could not be read as an image."
        }
    }
}

enum WorkspacePasteboardImportError: LocalizedError {
    case invalidDestination(String)
    case unsupportedSource(String)
    case sourceContainsDestination(String)
    case couldNotEncodeImage

    var errorDescription: String? {
        switch self {
        case .invalidDestination(let name):
            return "\(name) is not a folder."
        case .unsupportedSource(let name):
            return "\(name) cannot be imported from the clipboard."
        case .sourceContainsDestination(let name):
            return "\(name) cannot be pasted into itself."
        case .couldNotEncodeImage:
            return "The clipboard image could not be converted to PNG."
        }
    }
}

extension WorkspaceStore {
    /// Copy and Cut for a workspace file or folder, as in Finder: the item goes on the pasteboard
    /// and the next Paste in Monknot copies or moves it. A file goes on it as it is now, unsaved
    /// changes included.
    func putItemOnPasteboard(at url: URL, cutting: Bool, pasteboard: NSPasteboard = .general) {
        putItemsOnPasteboard(at: [url], cutting: cutting, pasteboard: pasteboard)
    }

    /// Copy and Cut for several workspace files and folders at once, as for one. An item inside
    /// another one given goes with it.
    func putItemsOnPasteboard(at urls: [URL], cutting: Bool, pasteboard: NSPasteboard = .general) {
        let urls = Self.outermostItems(urls)
        guard !isBusy, !urls.isEmpty else { return }
        let stamp: WorkspacePasteboardTransferStamp
        do {
            stamp = try WorkspacePasteboardExportService.copyFiles(
                urls.map { WorkspacePasteboardCopiedItem(url: $0, unsavedText: dirtyTextByDocumentID[$0.path]) },
                to: pasteboard
            )
        } catch {
            // The pasteboard may no longer hold the items of an earlier Copy or Cut.
            discardPendingTransfer()
            let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
            errorMessage = "Could not copy \(name): \(error.localizedDescription)"
            return
        }
        if cutting {
            cutItems(at: urls, pasteboardStamp: stamp)
        } else {
            copyItems(at: urls, pasteboardStamp: stamp)
        }
    }

    /// Pastes into `directoryURL` (the root when nil): the pending Copy or Cut while the pasteboard
    /// still holds the item it wrote, another window's Cut (which moves its item here), otherwise
    /// the pasteboard's files, image or text. Another window's Copy or Cut, or any other app's
    /// copy, replaces that item and so ends the transfer. Returns false when there is nothing to
    /// paste.
    @discardableResult
    func pasteFromPasteboard(_ pasteboard: NSPasteboard = .general, into directoryURL: URL?) -> Bool {
        if let stamp = pendingTransferPasteboardStamp,
           WorkspacePasteboardExportService.holdsTransfer(stamp, on: pasteboard) {
            pasteDocumentTransfer(into: directoryURL)
            return true
        }
        discardPendingTransfer()

        if let owner = otherWindowStores.first(where: { store in
            guard store.hasPendingCut, let stamp = store.pendingTransferPasteboardStamp else { return false }
            return WorkspacePasteboardExportService.holdsTransfer(stamp, on: pasteboard)
        }) {
            pasteCut(from: owner, into: directoryURL)
            return true
        }

        do {
            let items = try WorkspacePasteboardImportService.importItems(from: pasteboard)
            guard !items.isEmpty else { return false }
            importPasteboardItems(items, into: directoryURL)
            return true
        } catch {
            errorMessage = "Could not read clipboard contents: \(error.localizedDescription)"
            return true
        }
    }

    /// Whether Paste has something to paste from `pasteboard`, checked from its types alone.
    func canPaste(from pasteboard: NSPasteboard = .general) -> Bool {
        workspaceURL != nil && WorkspacePasteboardImportService.canImportItems(from: pasteboard)
    }
}
