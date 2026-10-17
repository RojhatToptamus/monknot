import AppKit
import MonknotCore
import SwiftUI
import WebKit

// Preview edits Markdown in place. The page turns every edit into one text patch on the Markdown
// source and posts it here; the store applies it and this side keeps the undo history. The page
// never sends HTML back, so Markdown it does not render is kept exactly as written.

/// A Markdown toolbar command for the visual editor while Preview is on screen.
struct MarkdownVisualEditorCommandRequest: Equatable {
    let serial: Int
    let command: MarkdownTextEditorCommand
}

struct MarkdownVisualEditorSelection: Equatable {
    let anchor: Int
    let head: Int

    var range: NSRange {
        NSRange(location: min(anchor, head), length: abs(head - anchor))
    }

    init(anchor: Int, head: Int) {
        self.anchor = max(0, anchor)
        self.head = max(0, head)
    }

    init?(_ value: Any?) {
        guard let body = value as? [String: Any],
              let anchor = WebViewBridge.integer(body["anchor"]),
              let head = WebViewBridge.integer(body["head"])
        else { return nil }
        self.init(anchor: anchor, head: head)
    }

    var payload: [String: Any] {
        ["anchor": anchor, "head": head]
    }
}

/// The block and inline formatting at the selection, which the Markdown toolbar reflects.
struct MarkdownVisualFormattingState: Equatable {
    enum Block: String {
        case paragraph
        case heading1, heading2, heading3, heading4, heading5, heading6
        case bullet, numbered, todo, quote, code, table

        var title: String {
            switch self {
            case .paragraph: return "Paragraph"
            case .heading1: return "Heading 1"
            case .heading2: return "Heading 2"
            case .heading3: return "Heading 3"
            case .heading4: return "Heading 4"
            case .heading5: return "Heading 5"
            case .heading6: return "Heading 6"
            case .bullet: return "Bullet List"
            case .numbered: return "Numbered List"
            case .todo: return "Task List"
            case .quote: return "Quote"
            case .code: return "Code Block"
            case .table: return "Table"
            }
        }
    }

    var block: Block
    var bold: Bool
    var italic: Bool
    var strikethrough: Bool
    var code: Bool
    var link: Bool
    var canFormat: Bool

    init(
        block: Block = .paragraph,
        bold: Bool = false,
        italic: Bool = false,
        strikethrough: Bool = false,
        code: Bool = false,
        link: Bool = false,
        canFormat: Bool = true
    ) {
        self.block = block
        self.bold = bold
        self.italic = italic
        self.strikethrough = strikethrough
        self.code = code
        self.link = link
        self.canFormat = canFormat
    }

    init(_ body: [String: Any]) {
        self.init(
            block: (body["block"] as? String).flatMap(Block.init(rawValue:)) ?? .paragraph,
            bold: WebViewBridge.boolean(body["strong"]) ?? false,
            italic: WebViewBridge.boolean(body["em"]) ?? false,
            strikethrough: WebViewBridge.boolean(body["del"]) ?? false,
            code: WebViewBridge.boolean(body["code"]) ?? false,
            link: WebViewBridge.boolean(body["link"]) ?? false,
            canFormat: WebViewBridge.boolean(body["canFormat"]) ?? true
        )
    }

    func isActive(_ command: MarkdownTextEditorCommand) -> Bool {
        switch command {
        case .bold: return bold
        case .italic: return italic
        case .code: return code
        case .link: return link
        case .quote: return block == .quote
        case .bulletList: return block == .bullet
        case .numberedList: return block == .numbered
        case .taskList: return block == .todo
        case .paragraph, .heading, .image, .horizontalRule: return false
        }
    }
}

/// One patch the visual editor applied to the Markdown source.
struct MarkdownVisualEditorChange: Equatable {
    enum Kind: String {
        case typing, delete, enter, format, paste, undo, redo, external, remote

        /// Changes the app itself asked for; they never become new undo steps.
        var isReplay: Bool {
            self == .undo || self == .redo || self == .external || self == .remote
        }
    }

    let version: Int
    let range: NSRange
    let removed: String
    let inserted: String
    let selectionBefore: MarkdownVisualEditorSelection?
    let selectionAfter: MarkdownVisualEditorSelection?
    let kind: Kind
    let group: Int
    let coalesce: Bool
    let label: String

    static func parse(_ body: [String: Any]) -> MarkdownVisualEditorChange? {
        guard let version = WebViewBridge.integer(body["v"]),
              let from = WebViewBridge.integer(body["from"]),
              let to = WebViewBridge.integer(body["to"]),
              from >= 0, to >= from,
              let removed = body["removed"] as? String,
              let inserted = body["inserted"] as? String,
              (removed as NSString).length == to - from
        else { return nil }
        return MarkdownVisualEditorChange(
            version: version,
            range: NSRange(location: from, length: to - from),
            removed: removed,
            inserted: inserted,
            selectionBefore: MarkdownVisualEditorSelection(body["selectionBefore"]),
            selectionAfter: MarkdownVisualEditorSelection(body["selectionAfter"]),
            kind: (body["kind"] as? String).flatMap(Kind.init(rawValue:)) ?? .typing,
            group: WebViewBridge.integer(body["group"]) ?? 0,
            coalesce: WebViewBridge.boolean(body["coalesce"]) ?? false,
            label: (body["label"] as? String) ?? ""
        )
    }
}

/// A text patch the app asks the page to apply (undo, redo, an external change).
struct MarkdownVisualEditorPatch: Equatable {
    let location: Int
    let removed: String
    let inserted: String

    var inverse: MarkdownVisualEditorPatch {
        MarkdownVisualEditorPatch(location: location, removed: inserted, inserted: removed)
    }
}

@MainActor
protocol MarkdownVisualEditorChannel: AnyObject {
    func applyFromApp(
        _ patches: [MarkdownVisualEditorPatch],
        selection: MarkdownVisualEditorSelection?,
        reason: MarkdownVisualEditorChange.Kind
    )
}

/// The visual editor's undo history. WebKit registers its own editing commands with the undo
/// manager of its view; the page cancels every input and applies a source patch instead, so those
/// commands never apply and their registrations are dropped.
final class MarkdownVisualEditorUndoManager: UndoManager {
    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {}
}

/// Undo history for one window's visual editor. It outlives the page, so switching between Source
/// and Preview keeps it; it starts over when another document is shown. Steps check the text they
/// change before applying, so an undo that no longer fits beeps instead of changing anything else.
@MainActor
final class MarkdownVisualEditingSession {
    let undoManager: MarkdownVisualEditorUndoManager = {
        let manager = MarkdownVisualEditorUndoManager()
        manager.levelsOfUndo = 500
        return manager
    }()
    private(set) var documentID: String?
    weak var channel: MarkdownVisualEditorChannel?
    private var openStep: Step?

    final class Step {
        var patches: [MarkdownVisualEditorPatch]
        var selectionBefore: MarkdownVisualEditorSelection?
        var selectionAfter: MarkdownVisualEditorSelection?
        let group: Int
        let kind: MarkdownVisualEditorChange.Kind
        let label: String

        init(_ change: MarkdownVisualEditorChange) {
            patches = [MarkdownVisualEditorPatch(
                location: change.range.location,
                removed: change.removed,
                inserted: change.inserted
            )]
            selectionBefore = change.selectionBefore
            selectionAfter = change.selectionAfter
            group = change.group
            kind = change.kind
            label = change.label
        }

        var actionName: String {
            if !label.isEmpty { return label }
            switch kind {
            case .typing: return "Typing"
            case .delete: return "Delete"
            case .enter: return "Typing"
            case .paste: return "Paste"
            case .format: return "Format"
            default: return ""
            }
        }

        /// Folds a change into this step: the next character of a typing run, the next backspace,
        /// or another patch from the same action.
        func absorb(_ change: MarkdownVisualEditorChange) -> Bool {
            guard var last = patches.last else { return false }
            let location = change.range.location
            if change.group == group {
                patches.append(MarkdownVisualEditorPatch(
                    location: location,
                    removed: change.removed,
                    inserted: change.inserted
                ))
                selectionAfter = change.selectionAfter
                return true
            }
            guard change.coalesce, change.kind == kind else { return false }
            let lastInsertedLength = (last.inserted as NSString).length
            if change.removed.isEmpty, location == last.location + lastInsertedLength {
                last = MarkdownVisualEditorPatch(location: last.location, removed: last.removed, inserted: last.inserted + change.inserted)
            } else if change.inserted.isEmpty, last.inserted.isEmpty, NSMaxRange(change.range) == last.location {
                last = MarkdownVisualEditorPatch(location: location, removed: change.removed + last.removed, inserted: "")
            } else if change.inserted.isEmpty, last.inserted.isEmpty, location == last.location {
                last = MarkdownVisualEditorPatch(location: location, removed: last.removed + change.removed, inserted: "")
            } else {
                return false
            }
            patches[patches.count - 1] = last
            selectionAfter = change.selectionAfter
            return true
        }
    }

    func prepare(documentID: String) {
        guard self.documentID != documentID else { return }
        self.documentID = documentID
        undoManager.removeAllActions()
        openStep = nil
    }

    func record(_ change: MarkdownVisualEditorChange) {
        guard !change.kind.isReplay else { return }
        if let openStep, openStep.absorb(change) { return }
        let step = Step(change)
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.undo(step) }
        }
        undoManager.setActionName(step.actionName)
        openStep = step
    }

    /// Ends the current typing run, so the next keystroke starts a new undo step.
    func breakCoalescing() {
        openStep = nil
    }

    private func undo(_ step: Step) {
        openStep = nil
        channel?.applyFromApp(step.patches.reversed().map(\.inverse), selection: step.selectionBefore, reason: .undo)
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.redo(step) }
        }
        undoManager.setActionName(step.actionName)
    }

    private func redo(_ step: Step) {
        openStep = nil
        channel?.applyFromApp(step.patches, selection: step.selectionAfter, reason: .redo)
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.undo(step) }
        }
        undoManager.setActionName(step.actionName)
    }
}

/// What a page hosting the visual editor needs from the app.
struct MarkdownVisualEditingConfiguration {
    let session: MarkdownVisualEditingSession
    /// The selection to show when the editor opens: the one Source left, as source offsets.
    let initialSelection: DocumentTextSelection?
    let commandRequest: MarkdownVisualEditorCommandRequest?
    /// The store's text, to resynchronize when a change could not be applied.
    let currentText: () -> String
    /// Applies a change to the store; false when the store refused it.
    let applyChange: (MarkdownVisualEditorChange) -> Bool
    let onSelectionChange: (MarkdownVisualEditorSelection, String) -> Void
    let onFormattingChange: (MarkdownVisualFormattingState) -> Void
    let onImagePasteRequest: ((MarkdownImagePasteRequest) -> Void)?
    let onFileDropRequest: ((MarkdownFileDropRequest) -> Void)?
}

/// The Preview web view. With a visual editing session it hands the Edit menu that session's undo
/// history and keeps Writing Tools out of the page, which edits only through source patches.
final class MarkdownEditorWebView: WKWebView {
    weak var visualEditingSession: MarkdownVisualEditingSession?

    override var undoManager: UndoManager? {
        visualEditingSession?.undoManager ?? super.undoManager
    }
}

/// SF Symbols for the page's menus and toolbars, drawn once as alpha masks the page tints with the
/// theme's ink. Sizes follow design.md §8: 15 beside a label, 17 alone in a button, 11 for a check.
enum MarkdownEditorSymbolAssets {
    private static let menuSymbols = [
        "text.alignleft", "list.bullet", "list.number", "checklist", "text.quote",
        "chevron.left.forwardslash.chevron.right", "tablecells", "minus", "photo", "link",
        "calendar", "arrow.up.to.line", "arrow.down.to.line", "arrow.left.to.line",
        "arrow.right.to.line", "trash", "magnifyingglass"
    ]
    private static let toolSymbols = [
        "bold", "italic", "strikethrough", "curlybraces", "link", "arrow.up.right.square",
        "pencil", "trash", "link.badge.minus"
    ]
    private static let smallSymbols = ["checkmark"]

    @MainActor private static var cached: [String: [String: Any]]?

    /// Icons keyed `context:name`, each a PNG data URL with its size in points at zoom 1.
    @MainActor
    static func icons() -> [String: [String: Any]] {
        if let cached { return cached }
        var result: [String: [String: Any]] = [:]
        let sets: [(String, [String], CGFloat)] = [("menu", menuSymbols, 15), ("tool", toolSymbols, 17), ("small", smallSymbols, 11)]
        for (context, names, nominal) in sets {
            for name in names {
                let resolved = MonknotSFSymbol.resolve(name, fallback: name == "link.badge.minus" ? "xmark" : "questionmark")
                let pointSize = MonknotSymbolOptics.pointSizeBase(for: resolved, nominal: nominal)
                if let icon = icon(resolved, pointSize: pointSize) {
                    result["\(context):\(name)"] = icon
                }
            }
        }
        cached = result
        return result
    }

    private static func icon(_ name: String, pointSize: CGFloat) -> [String: Any]? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
        else { return nil }
        let size = symbol.size
        guard size.width > 0, size.height > 0 else { return nil }
        // Four pixels per point stays sharp at 2× zoom on a Retina display.
        let scale: CGFloat = 4
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * scale)),
            pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        symbol.draw(in: NSRect(origin: .zero, size: size))
        context.flushGraphics()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return [
            "url": "data:image/png;base64,\(png.base64EncodedString())",
            "width": Double(size.width),
            "height": Double(size.height)
        ]
    }
}

extension MarkdownTextEditorCommand {
    /// The visual editor's name for the command and its argument.
    var visualEditorCommand: (name: String, value: Any?) {
        switch self {
        case .paragraph: return ("paragraph", nil)
        case .heading(let level): return ("heading", level)
        case .bold: return ("bold", nil)
        case .italic: return ("italic", nil)
        case .quote: return ("quote", nil)
        case .code: return ("code", nil)
        case .link: return ("link", nil)
        case .bulletList: return ("bulletList", nil)
        case .numberedList: return ("numberedList", nil)
        case .taskList: return ("taskList", nil)
        case .image: return ("image", nil)
        case .horizontalRule: return ("horizontalRule", nil)
        }
    }
}

/// The common prefix and suffix of two texts in UTF-16, as the patch that turns `old` into `new`.
enum MarkdownTextDifference {
    static func patch(from old: String, to new: String) -> MarkdownVisualEditorPatch? {
        guard old != new else { return nil }
        let a = old as NSString
        let b = new as NSString
        let aLength = a.length
        let bLength = b.length
        var prefix = 0
        let limit = min(aLength, bLength)
        while prefix < limit, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix,
              a.character(at: aLength - 1 - suffix) == b.character(at: bLength - 1 - suffix) {
            suffix += 1
        }
        // Never split a surrogate pair.
        if prefix > 0, prefix < aLength, UTF16.isTrailSurrogate(a.character(at: prefix)) { prefix -= 1 }
        if suffix > 0, aLength - suffix > prefix, UTF16.isTrailSurrogate(a.character(at: aLength - suffix)) {
            suffix -= 1
        }
        return MarkdownVisualEditorPatch(
            location: prefix,
            removed: a.substring(with: NSRange(location: prefix, length: aLength - prefix - suffix)),
            inserted: b.substring(with: NSRange(location: prefix, length: bLength - prefix - suffix))
        )
    }
}
