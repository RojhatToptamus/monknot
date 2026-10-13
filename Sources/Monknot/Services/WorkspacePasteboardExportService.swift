import AppKit
import Foundation
import MonknotCore

/// Identifies the pasteboard item one Copy or Cut of a workspace item wrote. The item carries the
/// identifier for as long as the pasteboard holds it, including after a failed text copy restores it.
struct WorkspacePasteboardTransferStamp: Equatable, Sendable {
    let pasteboardName: String
    let id: String
}

@MainActor
enum WorkspacePasteboardExportService {
    /// The copied workspace item's own URL, beside the exported snapshot that other apps read.
    nonisolated static let workspaceFileURLType = NSPasteboard.PasteboardType("com.monknot.workspace-file-url")
    nonisolated static let transferIDType = NSPasteboard.PasteboardType("com.monknot.workspace-transfer-id")

    private static var exportedDirectoryURL: URL?

    /// Puts a file snapshot (or a folder itself) on the pasteboard, as Finder's Copy does, together
    /// with the item's workspace URL so Monknot can link to the original instead of importing a copy.
    @discardableResult
    static func copyFile(at url: URL, to pasteboard: NSPasteboard = .general) throws -> WorkspacePasteboardTransferStamp {
        let sourceURL = url.standardizedFileURL
        let isRegularFile = try sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        let snapshotDirectoryURL = isRegularFile ? makeSnapshot(of: sourceURL) : nil
        let exportedURL = snapshotDirectoryURL?.appendingPathComponent(sourceURL.lastPathComponent) ?? sourceURL
        let stamp = WorkspacePasteboardTransferStamp(
            pasteboardName: pasteboard.name.rawValue,
            id: UUID().uuidString
        )

        let item = NSPasteboardItem()
        item.setString(exportedURL.absoluteString, forType: .fileURL)
        item.setString(sourceURL.absoluteString, forType: workspaceFileURLType)
        item.setString(stamp.id, forType: transferIDType)

        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            if let snapshotDirectoryURL {
                try? FileManager.default.removeItem(at: snapshotDirectoryURL)
            }
            throw WorkspacePasteboardExportError.couldNotWritePasteboard
        }

        cleanupExport()
        exportedDirectoryURL = snapshotDirectoryURL
        return stamp
    }

    static func copyPlainText(
        _ text: String,
        to pasteboard: NSPasteboard = .general,
        write: ((String, NSPasteboard) -> Bool)? = nil
    ) throws {
        guard !text.isEmpty else {
            throw WorkspacePasteboardExportError.emptyText
        }

        guard let previousItems = copiedPasteboardItems(pasteboard.pasteboardItems ?? []) else {
            throw WorkspacePasteboardExportError.couldNotWritePasteboard
        }
        pasteboard.clearContents()
        let didWrite = write?(text, pasteboard)
            ?? pasteboard.setString(text, forType: .string)
        guard didWrite else {
            pasteboard.clearContents()
            if !previousItems.isEmpty {
                _ = pasteboard.writeObjects(previousItems)
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

    /// The workspace items a Monknot Copy or Cut put on the pasteboard, when they still exist.
    nonisolated static func workspaceFileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        let urls = (pasteboard.pasteboardItems ?? []).compactMap { item -> URL? in
            guard let string = item.string(forType: workspaceFileURLType),
                  let url = URL(string: string),
                  url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            return url
        }
        return urls.isEmpty ? nil : urls
    }

    /// Whether `pasteboard` still holds the item the stamped Copy or Cut wrote.
    static func holdsTransfer(_ stamp: WorkspacePasteboardTransferStamp, on pasteboard: NSPasteboard) -> Bool {
        pasteboard.name.rawValue == stamp.pasteboardName
            && pasteboard.string(forType: transferIDType) == stamp.id
    }

    /// Empties the stamped pasteboard when it still holds the item that Copy or Cut wrote.
    static func clearTransfer(_ stamp: WorkspacePasteboardTransferStamp) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(stamp.pasteboardName))
        guard holdsTransfer(stamp, on: pasteboard) else { return }
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

    /// A hard link to the file in a fresh export folder, so the pasted content is the copied one
    /// even when the original is saved over before Paste. Nil when the volume has no hard links;
    /// the file then goes on the pasteboard as itself, without copying its contents.
    private static func makeSnapshot(of sourceURL: URL) -> URL? {
        guard let directoryURL = try? makeExportDirectory() else { return nil }
        do {
            try FileManager.default.linkItem(
                at: sourceURL,
                to: directoryURL.appendingPathComponent(sourceURL.lastPathComponent)
            )
            return directoryURL
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            return nil
        }
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
