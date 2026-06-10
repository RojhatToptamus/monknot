import AppKit
import Foundation

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

    private static func uniqueURL(for proposedName: String, in directoryURL: URL) -> URL {
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

    private static func sanitizedFileName(_ name: String, fallback: String) -> String {
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

    private static func pngData(for image: NSImage) -> Data? {
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
