import AppKit
import Foundation

enum MarkdownSemanticPasteboardExportError: Error, LocalizedError {
    case pasteboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .pasteboardWriteFailed:
            return "The rendered Markdown could not be copied."
        }
    }
}

struct MarkdownSemanticPasteboardRepresentations {
    let plainText: String
    let html: Data
    let rtf: Data
}

enum MarkdownSemanticPasteboardExportService {
    static func representations(for markdown: String) throws -> MarkdownSemanticPasteboardRepresentations? {
        guard !markdown.isEmpty else { return nil }
        let markdownData = Data(markdown.utf8)
        let attributed = try NSAttributedString(
            markdown: markdownData,
            options: .init(interpretedSyntax: .full),
            baseURL: nil
        )
        let fullRange = NSRange(location: 0, length: attributed.length)
        let html = try attributed.data(
            from: fullRange,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
        )
        let rtf = try attributed.data(
            from: fullRange,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtf,
            ]
        )
        return MarkdownSemanticPasteboardRepresentations(
            plainText: attributed.string,
            html: html,
            rtf: rtf
        )
    }

    @MainActor
    @discardableResult
    static func copy(_ markdown: String, to pasteboard: NSPasteboard = .general) throws -> Bool {
        guard let item = try pasteboardItem(for: markdown) else { return false }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw MarkdownSemanticPasteboardExportError.pasteboardWriteFailed
        }
        return true
    }

    static func pasteboardItem(for markdown: String) throws -> NSPasteboardItem? {
        guard let representations = try representations(for: markdown) else { return nil }
        let item = NSPasteboardItem()
        guard item.setString(representations.plainText, forType: .string),
              item.setData(representations.html, forType: .html),
              item.setData(representations.rtf, forType: .rtf)
        else {
            throw MarkdownSemanticPasteboardExportError.pasteboardWriteFailed
        }

        return item
    }
}
