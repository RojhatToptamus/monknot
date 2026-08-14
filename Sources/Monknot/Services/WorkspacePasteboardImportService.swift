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

        if let text = pasteboard.string(forType: .string),
           let item = capturedTextItem(from: text, isURL: false) {
            return [item]
        }

        return []
    }

    static func importItems(_ items: [WorkspacePasteboardImportItem], into directoryURL: URL) throws -> [URL] {
        try validateDirectory(directoryURL)

        var importedURLs: [URL] = []
        for item in items {
            try Task.checkCancellation()

            switch item.payload {
            case .fileURL(let sourceURL):
                importedURLs.append(try copyFile(at: sourceURL, into: directoryURL))
            case .pngImageData(let data, let suggestedName):
                let destinationURL = uniqueURL(
                    for: sanitizedFileName(suggestedName, fallback: "Pasted Image.png"),
                    in: directoryURL
                )
                try data.write(to: destinationURL, options: .atomic)
                importedURLs.append(destinationURL)
            case .capturedMarkdown(let markdown, let suggestedName):
                let inboxURL = directoryURL.appendingPathComponent("inbox", isDirectory: true)
                try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
                let destinationURL = uniqueURL(
                    for: sanitizedFileName(suggestedName, fallback: "Clipboard.md"),
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

        if resourceValues.isDirectory == true, isURL(directoryURL, containedIn: sourceURL) {
            throw WorkspacePasteboardImportError.sourceContainsDestination(sourceURL.lastPathComponent)
        }

        let fileName = sanitizedFileName(sourceURL.lastPathComponent, fallback: "Pasted File")
        let destinationURL = uniqueURL(for: fileName, in: directoryURL)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private static func validateDirectory(_ url: URL) throws {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspacePasteboardImportError.invalidDestination(url.lastPathComponent)
        }
    }

    fileprivate static func uniqueURL(for proposedName: String, in directoryURL: URL) -> URL {
        let fileManager = FileManager.default
        let proposedURL = URL(fileURLWithPath: proposedName)
        let sourceExtension = proposedURL.pathExtension
        let baseName = proposedURL.deletingPathExtension().lastPathComponent
        var candidate = directoryURL.appendingPathComponent(proposedName)

        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }

        var index = 1
        repeat {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let name = sourceExtension.isEmpty
                ? "\(baseName)\(suffix)"
                : "\(baseName)\(suffix).\(sourceExtension)"
            candidate = directoryURL.appendingPathComponent(name)
            index += 1
        } while fileManager.fileExists(atPath: candidate.path)

        return candidate
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
        let fileName = sanitizedFileName("\(timestamp) \(title).md", fallback: "\(timestamp) Clipboard.md")
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

    private static func isURL(_ candidate: URL, containedIn directory: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return candidatePath == directoryPath || candidatePath.hasPrefix(prefix)
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

    fileprivate static func escapeMarkdownLabel(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["[", "]", "(", ")"] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return escaped
    }

    fileprivate static func percentEncodedMarkdownPath(_ path: String) -> String {
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
        let proposedName: String
        if item.isImage {
            let baseName = URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
            proposedName = "\(baseName).png"
        } else {
            proposedName = originalName
        }
        let destinationURL = WorkspacePasteboardImportService.uniqueURL(for: proposedName, in: assetsURL)
        guard isContained(destinationURL, in: root) else {
            throw MarkdownImageAssetError.outsideWorkspace
        }

        let temporaryURL = assetsURL.appendingPathComponent(".monknot-drop-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        if item.isImage {
            guard let image = NSImage(contentsOf: item.sourceURL),
                  let data = WorkspacePasteboardImportService.pngData(for: image)
            else {
                throw MarkdownImageAssetError.couldNotReadDroppedImage(item.sourceURL.lastPathComponent)
            }
            try data.write(to: temporaryURL, options: .atomic)
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
            return "Drop between 1 and \(maximum) files at a time."
        case .noDroppedFiles:
            return "The drop does not contain any new files."
        case .unsupportedDroppedFile(let name):
            return "\(name) is not a supported file. Folders, aliases, and binary files cannot be inserted."
        case .droppedFileTooLarge(let name):
            return "\(name) is too large to import."
        case .droppedFilesChanged:
            return "The dropped files changed before they could be imported."
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
