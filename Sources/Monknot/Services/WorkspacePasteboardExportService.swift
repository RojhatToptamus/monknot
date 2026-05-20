import AppKit
import Foundation

@MainActor
enum WorkspacePasteboardExportService {
    private static var exportedDirectoryURL: URL?
    private static var exportedPasteboardChangeCount: Int?

    static func copyFile(at url: URL, to pasteboard: NSPasteboard = .general) throws {
        let sourceURL = url.standardizedFileURL
        let exportDirectoryURL = try makeExportDirectory()
        let exportedURL = exportDirectoryURL.appendingPathComponent(sourceURL.lastPathComponent)

        do {
            try exportFile(at: sourceURL, to: exportedURL)
        } catch {
            try? FileManager.default.removeItem(at: exportDirectoryURL)
            throw error
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([exportedURL as NSURL]) else {
            try? FileManager.default.removeItem(at: exportDirectoryURL)
            throw WorkspacePasteboardExportError.couldNotWritePasteboard
        }

        let previousExportDirectoryURL = exportedDirectoryURL
        exportedDirectoryURL = exportDirectoryURL
        exportedPasteboardChangeCount = pasteboard.changeCount

        if let previousExportDirectoryURL {
            try? FileManager.default.removeItem(at: previousExportDirectoryURL)
        }
    }

    static func ownsPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard exportedDirectoryURL != nil else { return false }

        if exportedPasteboardChangeCount == pasteboard.changeCount {
            return true
        }

        cleanupExport()
        return false
    }

    static func clearFileTransferPasteboard(_ pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        cleanupExport()
    }

    private static func makeExportDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonknotPasteboardExport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private static func exportFile(at sourceURL: URL, to exportedURL: URL) throws {
        let resourceValues = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])

        if resourceValues.isRegularFile == true {
            do {
                try FileManager.default.linkItem(at: sourceURL, to: exportedURL)
                return
            } catch {
                // Some volumes do not support hard links; fall back to a real copy.
            }
        }

        try FileManager.default.copyItem(at: sourceURL, to: exportedURL)
    }

    private static func cleanupExport() {
        if let exportedDirectoryURL {
            try? FileManager.default.removeItem(at: exportedDirectoryURL)
        }
        exportedDirectoryURL = nil
        exportedPasteboardChangeCount = nil
    }
}

private enum WorkspacePasteboardExportError: LocalizedError {
    case couldNotWritePasteboard

    var errorDescription: String? {
        switch self {
        case .couldNotWritePasteboard:
            return "The file could not be written to the clipboard."
        }
    }
}
