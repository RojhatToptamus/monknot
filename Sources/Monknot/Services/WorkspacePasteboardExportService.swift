import AppKit
import Foundation
import MonknotCore

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

    static func copyPlainText(
        _ text: String,
        to pasteboard: NSPasteboard = .general,
        write: ((String, NSPasteboard) -> Bool)? = nil
    ) throws {
        guard !text.isEmpty else {
            throw WorkspacePasteboardExportError.emptyText
        }

        let wasOwnedFileTransfer = exportedDirectoryURL != nil
            && exportedPasteboardChangeCount == pasteboard.changeCount
        guard let previousItems = copiedPasteboardItems(pasteboard.pasteboardItems ?? []) else {
            throw WorkspacePasteboardExportError.couldNotWritePasteboard
        }
        pasteboard.clearContents()
        let didWrite = write?(text, pasteboard)
            ?? pasteboard.setString(text, forType: .string)
        guard didWrite else {
            pasteboard.clearContents()
            if !previousItems.isEmpty,
               pasteboard.writeObjects(previousItems),
               wasOwnedFileTransfer {
                exportedPasteboardChangeCount = pasteboard.changeCount
            }
            throw WorkspacePasteboardExportError.couldNotWritePasteboard
        }

        if pasteboard.name == .general {
            cleanupExport()
        }
    }

    @discardableResult
    static func copyRelativePath(
        for url: URL,
        in workspaceURL: URL,
        to pasteboard: NSPasteboard = .general
    ) throws -> String {
        let relativePath = try WorkspaceDocumentSupport.validatedRelativePath(
            for: url,
            in: workspaceURL
        )
        try copyPlainText(relativePath, to: pasteboard)
        return relativePath
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

    private static func copiedPasteboardItems(
        _ items: [NSPasteboardItem]
    ) -> [NSPasteboardItem]? {
        var copies: [NSPasteboardItem] = []
        copies.reserveCapacity(items.count)
        for item in items {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type),
                      copy.setData(data, forType: type)
                else { return nil }
            }
            copies.append(copy)
        }
        return copies
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
    case emptyText
    case couldNotWritePasteboard

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "There is no text to copy."
        case .couldNotWritePasteboard:
            return "The content could not be written to the clipboard."
        }
    }
}
