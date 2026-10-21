import AppKit
import Foundation
import MonknotCore

/// Identifies the pasteboard item one Copy or Cut of a workspace item wrote. The item carries the
/// identifier for as long as the pasteboard holds it, including after a failed text copy restores it.
struct WorkspacePasteboardTransferStamp: Equatable, Sendable {
    let pasteboardName: String
    let id: String
    /// Each copied file as of the Copy or Cut, by the file's path, which its item holds in place of
    /// the file itself.
    let snapshotURLs: [String: URL]

    /// The snapshot of the one file copied.
    var snapshotURL: URL? {
        snapshotURLs.count == 1 ? snapshotURLs.values.first : nil
    }

    func snapshotURL(for sourceURL: URL) -> URL? {
        snapshotURLs[sourceURL.standardizedFileURL.path]
    }
}

@MainActor
enum WorkspacePasteboardExportService {
    /// The copied workspace item's own URL, beside the exported snapshot that other apps read.
    nonisolated static let workspaceFileURLType = NSPasteboard.PasteboardType("com.monknot.workspace-file-url")
    nonisolated static let transferIDType = NSPasteboard.PasteboardType("com.monknot.workspace-transfer-id")

    private static var exportedDirectoryURLs: [URL] = []

    /// Puts a snapshot of a file (or a folder itself) on the pasteboard, together with the item's
    /// workspace URL so Monknot can link to the original instead of importing a copy. The snapshot
    /// is the file as of the Copy, with `unsavedText` in place of its saved text: what any app, and
    /// a Paste in Monknot, copies for as long as the pasteboard holds it. A folder is copied as it
    /// is at Paste.
    @discardableResult
    static func copyFile(
        at url: URL,
        unsavedText: String? = nil,
        to pasteboard: NSPasteboard = .general
    ) throws -> WorkspacePasteboardTransferStamp {
        try copyFiles([WorkspacePasteboardCopiedItem(url: url, unsavedText: unsavedText)], to: pasteboard)
    }

    /// Puts several files and folders on the pasteboard at once, one item each, as `copyFile` puts
    /// one; every item carries the one stamp.
    @discardableResult
    static func copyFiles(
        _ items: [WorkspacePasteboardCopiedItem],
        to pasteboard: NSPasteboard = .general
    ) throws -> WorkspacePasteboardTransferStamp {
        let stampID = UUID().uuidString
        var snapshotURLs: [String: URL] = [:]
        var snapshotDirectoryURLs: [URL] = []
        var pasteboardItems: [NSPasteboardItem] = []
        for copied in items {
            let sourceURL = copied.url.standardizedFileURL
            let isRegularFile = try sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            let snapshotDirectoryURL = isRegularFile ? makeSnapshot(of: sourceURL, unsavedText: copied.unsavedText) : nil
            let snapshotURL = snapshotDirectoryURL?.appendingPathComponent(sourceURL.lastPathComponent)
            if let snapshotDirectoryURL, let snapshotURL {
                snapshotDirectoryURLs.append(snapshotDirectoryURL)
                snapshotURLs[sourceURL.path] = snapshotURL
            }

            let item = NSPasteboardItem()
            item.setString((snapshotURL ?? sourceURL).absoluteString, forType: .fileURL)
            item.setString(sourceURL.absoluteString, forType: workspaceFileURLType)
            item.setString(stampID, forType: transferIDType)
            pasteboardItems.append(item)
        }

        pasteboard.clearContents()
        guard !pasteboardItems.isEmpty, pasteboard.writeObjects(pasteboardItems) else {
            for directoryURL in snapshotDirectoryURLs {
                try? FileManager.default.removeItem(at: directoryURL)
            }
            throw WorkspacePasteboardExportError.couldNotWritePasteboard
        }

        cleanupExport()
        exportedDirectoryURLs = snapshotDirectoryURLs
        return WorkspacePasteboardTransferStamp(
            pasteboardName: pasteboard.name.rawValue,
            id: stampID,
            snapshotURLs: snapshotURLs
        )
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

    /// The file as it is now, in a fresh export folder, so the pasted content is the copied one even
    /// when the original is saved over before Paste: `unsavedText` written out when given, otherwise
    /// a hard link to the file. Nil when the volume has no hard links; the file then goes on the
    /// pasteboard as itself, without copying its contents.
    private static func makeSnapshot(of sourceURL: URL, unsavedText: String?) -> URL? {
        guard let directoryURL = try? makeExportDirectory() else { return nil }
        let snapshotURL = directoryURL.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            if let unsavedText {
                try Data(unsavedText.utf8).write(to: snapshotURL, options: .withoutOverwriting)
            } else {
                try FileManager.default.linkItem(at: sourceURL, to: snapshotURL)
            }
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
        for directoryURL in exportedDirectoryURLs {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        exportedDirectoryURLs = []
    }
}

/// A workspace file or folder Copy or Cut puts on the pasteboard, with its unsaved text.
struct WorkspacePasteboardCopiedItem: Sendable {
    let url: URL
    var unsavedText: String?
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
