import AppKit
import Foundation

struct WorkspacePasteboardImportItem: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case fileURL(URL)
        case pngImageData(Data, suggestedName: String)
    }

    let payload: Payload

    static func fileURL(_ url: URL) -> WorkspacePasteboardImportItem {
        WorkspacePasteboardImportItem(payload: .fileURL(url))
    }

    static func pngImageData(_ data: Data, suggestedName: String = "Pasted Image.png") -> WorkspacePasteboardImportItem {
        WorkspacePasteboardImportItem(payload: .pngImageData(data, suggestedName: suggestedName))
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
        return try imageObjects.enumerated().compactMap { index, object in
            guard let image = object as? NSImage else { return nil }
            guard let pngData = pngData(for: image) else {
                throw WorkspacePasteboardImportError.couldNotEncodeImage
            }

            let suggestedName = imageObjects.count == 1
                ? "Pasted Image.png"
                : "Pasted Image \(index + 1).png"
            return .pngImageData(pngData, suggestedName: suggestedName)
        }
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
