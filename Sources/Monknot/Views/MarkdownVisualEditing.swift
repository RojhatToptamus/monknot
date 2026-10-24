import AppKit
import MonknotCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// Preview edits Markdown in place. The page turns every edit into one text patch on the Markdown
// source and posts it here; the store applies it and this side keeps the undo history. The page
// never sends HTML back, so Markdown it does not render is kept exactly as written.

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

/// One patch the visual editor applied to the Markdown source.
struct MarkdownVisualEditorChange: Equatable {
    enum Kind: String {
        /// `flow`: a writing-assistance fix or completion the user took; one undo step of its own.
        case typing, delete, enter, format, paste, undo, redo, external, remote, flow

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
    /// Patches of one action, or of one typing run, share a group and make one undo step.
    let group: Int
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
            label: (body["label"] as? String) ?? ""
        )
    }
}

/// A text patch on the source: one the page made, or one the app asks the page to apply (undo,
/// redo, an external change). An undo step keeps up to 32 characters of the text on each side
/// (`before`, `after`), so it applies only where that text still is.
struct MarkdownVisualEditorPatch: Equatable {
    static let contextLength = 32

    let location: Int
    let removed: String
    let inserted: String
    var before = ""
    var after = ""

    var inverse: MarkdownVisualEditorPatch {
        MarkdownVisualEditorPatch(location: location, removed: inserted, inserted: removed, before: before, after: after)
    }

    /// The patch with the text around it in `text`, the text it applies to.
    func withContext(in text: NSString) -> MarkdownVisualEditorPatch {
        let end = location + (removed as NSString).length
        guard location >= 0, end <= text.length else { return self }
        var start = max(0, location - Self.contextLength)
        var limit = min(text.length, end + Self.contextLength)
        // Never split a surrogate pair.
        if start > 0, start < location, UTF16.isTrailSurrogate(text.character(at: start)) { start += 1 }
        if limit < text.length, limit > end, UTF16.isLeadSurrogate(text.character(at: limit - 1)) { limit -= 1 }
        var patch = self
        patch.before = text.substring(with: NSRange(location: start, length: location - start))
        patch.after = text.substring(with: NSRange(location: end, length: limit - end))
        return patch
    }

    /// This patch followed by `next` as one patch, when `next` continues it: typing on after it,
    /// or deleting the character before or after it.
    func merging(_ next: MarkdownVisualEditorPatch) -> MarkdownVisualEditorPatch? {
        if next.removed.isEmpty, next.location == location + (inserted as NSString).length {
            return MarkdownVisualEditorPatch(location: location, removed: removed, inserted: inserted + next.inserted, before: before, after: after)
        }
        guard inserted.isEmpty, next.inserted.isEmpty else { return nil }
        if next.location + (next.removed as NSString).length == location {
            return MarkdownVisualEditorPatch(location: next.location, removed: next.removed + removed, inserted: "", before: next.before, after: after)
        }
        if next.location == location {
            return MarkdownVisualEditorPatch(location: location, removed: removed + next.removed, inserted: "", before: before, after: next.after)
        }
        return nil
    }

    /// Applies `patches` in order to a copy of `text`, each only where its removed text and context
    /// still are, and returns the one patch they add up to (removing what it inserts when they
    /// change nothing). Nil when any of them no longer fits, so a step applies whole or not at all.
    static func combined(_ patches: [MarkdownVisualEditorPatch], appliedTo text: String) -> MarkdownVisualEditorPatch? {
        guard !patches.isEmpty else { return MarkdownVisualEditorPatch(location: 0, removed: "", inserted: "") }
        let buffer = NSMutableString(string: text)
        let length = buffer.length
        // The text before `head` and the last `tail` characters are the same before and after.
        var head = length
        var tail = length
        for patch in patches {
            let removedLength = (patch.removed as NSString).length
            let beforeLength = (patch.before as NSString).length
            let afterLength = (patch.after as NSString).length
            let end = patch.location + removedLength
            guard patch.location >= beforeLength, end + afterLength <= buffer.length,
                  buffer.substring(with: NSRange(location: patch.location, length: removedLength)) == patch.removed,
                  buffer.substring(with: NSRange(location: patch.location - beforeLength, length: beforeLength)) == patch.before,
                  buffer.substring(with: NSRange(location: end, length: afterLength)) == patch.after
            else { return nil }
            head = min(head, patch.location)
            tail = min(tail, buffer.length - end)
            buffer.replaceCharacters(in: NSRange(location: patch.location, length: removedLength), with: patch.inserted)
        }
        return MarkdownVisualEditorPatch(
            location: head,
            removed: (text as NSString).substring(with: NSRange(location: head, length: length - tail - head)),
            inserted: buffer.substring(with: NSRange(location: head, length: buffer.length - tail - head))
        )
    }
}

@MainActor
protocol MarkdownVisualEditorChannel: AnyObject {
    /// Applies `patches` in order to the document and the page as one change; false, changing
    /// nothing, when they no longer fit its text.
    func applyFromApp(
        _ patches: [MarkdownVisualEditorPatch],
        selection: MarkdownVisualEditorSelection?,
        reason: MarkdownVisualEditorChange.Kind
    ) -> Bool
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
        /// In the order they were made, each on the text the one before it left.
        var patches: [MarkdownVisualEditorPatch]
        var selectionBefore: MarkdownVisualEditorSelection?
        var selectionAfter: MarkdownVisualEditorSelection?
        let group: Int
        let kind: MarkdownVisualEditorChange.Kind
        let label: String

        init(_ change: MarkdownVisualEditorChange, patch: MarkdownVisualEditorPatch) {
            patches = [patch]
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

        /// Folds the next patch of the step's action or typing run in: the next character typed or
        /// deleted joins the patch before it, anything else follows it.
        func absorb(_ change: MarkdownVisualEditorChange, patch: MarkdownVisualEditorPatch) {
            if let last = patches.last, let merged = last.merging(patch) {
                patches[patches.count - 1] = merged
            } else {
                patches.append(patch)
            }
            selectionAfter = change.selectionAfter
        }
    }

    func prepare(documentID: String) {
        guard self.documentID != documentID else { return }
        self.documentID = documentID
        clearHistory()
    }

    /// Records a change the page made, as `patch` on the document's text (with its context).
    func record(_ change: MarkdownVisualEditorChange, patch: MarkdownVisualEditorPatch) {
        guard !change.kind.isReplay else { return }
        if let openStep, openStep.group == change.group {
            openStep.absorb(change, patch: patch)
            return
        }
        let step = Step(change, patch: patch)
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.undo(step) }
        }
        undoManager.setActionName(step.actionName)
        openStep = step
    }

    /// Ends the current typing run, so the next keystroke starts a new undo step. A new page
    /// numbers its groups from the start again, so each render ends the run.
    func breakCoalescing() {
        openStep = nil
    }

    /// Forgets every step: the text changed outside the editor, so none of them fits any more.
    func clearHistory() {
        undoManager.removeAllActions()
        openStep = nil
    }

    private func undo(_ step: Step) {
        openStep = nil
        guard channel?.applyFromApp(step.patches.reversed().map(\.inverse), selection: step.selectionBefore, reason: .undo) == true else {
            NSSound.beep()
            return
        }
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.redo(step) }
        }
        undoManager.setActionName(step.actionName)
    }

    private func redo(_ step: Step) {
        openStep = nil
        guard channel?.applyFromApp(step.patches, selection: step.selectionAfter, reason: .redo) == true else {
            NSSound.beep()
            return
        }
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
    /// The store's text, to resynchronize when a change could not be applied.
    let currentText: () -> String
    /// Applies a patch to the store's text; false when the store refused it.
    let applyChange: (MarkdownVisualEditorPatch) -> Bool
    let onSelectionChange: (MarkdownVisualEditorSelection, String) -> Void
    let onImagePasteRequest: ((MarkdownImagePasteRequest) -> Void)?
    let onFileDropRequest: ((MarkdownFileDropRequest) -> Void)?
    /// The notes `[[` offers, ranked by `WikilinkAutocompleteService` as in Source.
    let wikilinkDocuments: [WorkspaceDocument]
    /// Creates the Page block's Markdown file from its name and returns its URL.
    var createPage: ((String) async throws -> URL)? = nil
    /// The writing-assistance settings, which Preview follows as Source does.
    var textCheckingOptions = EditorTextCheckingOptions.defaultValue
    /// Shows Source and opens Writing Tools there: Writing Tools rewrite text in place, and the page
    /// changes only through source patches.
    var showWritingTools: (() -> Void)? = nil
}

/// What the Image, Video, Audio and File blocks ask the user to pick.
enum MarkdownInsertedFileKind: String {
    case image
    case video
    case audio
    case file

    var contentTypes: [UTType] {
        switch self {
        case .image: return [.image]
        case .video: return [.movie]
        case .audio: return [.audio]
        case .file: return []
        }
    }

    var panelMessage: String {
        switch self {
        case .image: return "Choose an image to insert"
        case .video: return "Choose a video to insert"
        case .audio: return "Choose an audio file to insert"
        case .file: return "Choose a file to link"
        }
    }

    var undoLabel: String {
        switch self {
        case .image: return "Insert Image"
        case .video: return "Insert Video"
        case .audio: return "Insert Audio"
        case .file: return "Insert File"
        }
    }

    /// A dropped media file arrives as a plain link; video and audio become `![…](…)`, which the
    /// preview renders as a player.
    func markdown(fromDropMarkdown markdown: String) -> String {
        switch self {
        case .video, .audio:
            return markdown
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.hasPrefix("[") ? "!" + $0 : String($0) }
                .joined(separator: "\n")
        case .image, .file:
            return markdown
        }
    }
}

/// The Edit menu's writing commands while Preview edits the focused document.
@MainActor
protocol MarkdownPreviewEditorCommands: AnyObject {
    var canCheckDocumentNow: Bool { get }
    /// Check Document Now: the writing assistance checks the sentence before the caret at once.
    func checkDocumentNow() -> Bool
    var canShowWritingTools: Bool { get }
    /// Show Writing Tools: switches to Source, which opens them.
    func showWritingTools() -> Bool
}

/// The Preview web view. With a visual editing session it hands the Edit menu that session's undo
/// history and keeps Writing Tools out of the page, which edits only through source patches.
final class MarkdownEditorWebView: PaneTransitionWebView {
    weak var visualEditingSession: MarkdownVisualEditingSession?
    weak var previewCommands: MarkdownPreviewEditorCommands?
    /// The writing assistance running on this page; it registers itself once the page shows.
    weak var writingAssistance: MarkdownPreviewFlowCoordinator?

    /// WebKit's context-menu items all send this; the tag says which one it is.
    private static let webKitMenuAction = NSSelectorFromString("forwardContextMenuAction:")
    /// WebCore's tag for Ignore Spelling (`ContextMenuItemTagIgnoreSpelling`).
    static let webKitIgnoreSpellingTag = 17
    private weak var webKitMenuTarget: AnyObject?

    /// Preview's page reflows with the card's edges while a side pane moves.
    override class var paneTransitionMode: WebViewPaneTransitionHold.Mode { .reflow }

    override var undoManager: UndoManager? {
        visualEditingSession?.undoManager ?? super.undoManager
    }

    /// Ignore Spelling ignores the selected word in WebKit's own spelling document. The writing
    /// assistance checks with a document of its own, so the item now also ignores the word there,
    /// or Flow would keep flagging it and could fix it. (Learn Spelling needs nothing: it adds the
    /// word to the user's dictionary, which every document shares.)
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items
        where item.tag == Self.webKitIgnoreSpellingTag && item.action == Self.webKitMenuAction {
            webKitMenuTarget = item.target
            item.target = self
            item.action = #selector(ignoreSpelling(_:))
        }
    }

    @objc private func ignoreSpelling(_ item: NSMenuItem) {
        // WebKit reads which command this is from the item's tag and title, both unchanged.
        NSApp.sendAction(Self.webKitMenuAction, to: webKitMenuTarget, from: item)
        evaluateJavaScript("window.getSelection().toString()") { [weak self] value, _ in
            guard let word = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !word.isEmpty
            else { return }
            self?.writingAssistance?.ignoreWord(word)
        }
    }
}

/// SF Symbols for the page's menus and toolbars, drawn once as alpha masks the page tints with the
/// theme's ink. Sizes follow design.md §8: 15 beside a label, 17 alone in a button, and the chrome's
/// 10 semibold secondary marks for a check and a chevron.
enum MarkdownEditorSymbolAssets {
    /// Glyphs beside a label in the slash, block, Turn Into, Align, callout and table menus (15 nominal).
    static let menuSymbols = [
        "textformat", "list.bullet", "list.number", "checklist", "chevron.right.square", "doc",
        "text.bubble", "text.quote", "tablecells", "minus", "arrow.up.right.square", "photo",
        "play.rectangle", "speaker.wave.2", "chevron.left.forwardslash.chevron.right", "paperclip",
        "bookmark", "list.bullet.rectangle", "calendar", "face.smiling", "info.circle", "lightbulb",
        "exclamationmark.bubble", "exclamationmark.triangle", "exclamationmark.octagon",
        "arrow.triangle.2.circlepath", "plus.square.on.square", "doc.on.doc", "arrow.up", "arrow.down",
        "arrow.up.to.line", "arrow.down.to.line", "arrow.left.to.line", "arrow.right.to.line", "trash",
        "magnifyingglass", "doc.text", "link", "text.alignleft", "text.aligncenter", "text.alignright"
    ]
    /// Glyphs alone in a format bar, media bar or link card button (17 nominal).
    static let toolSymbols = [
        "bold", "italic", "strikethrough", "curlybraces", "link", "arrow.up.right.square",
        MonknotWorkspaceIcons.rename, "trash", "link.badge.minus", "text.alignleft", "text.aligncenter",
        "text.alignright"
    ]
    /// A menu row's check and submenu chevron, the chevron of a dropdown and a callout's title: the
    /// chrome's secondary marks (`MonknotSecondaryGlyph`), 10 semibold.
    static let smallSymbols = ["checkmark", "chevron.right", "chevron.down"]

    @MainActor private static var cached: [String: [String: Any]]?

    /// Icons keyed `context:name`, each a PNG data URL with its size in points at zoom 1.
    @MainActor
    static func icons() -> [String: [String: Any]] {
        if let cached { return cached }
        var result: [String: [String: Any]] = [:]
        let sets: [(String, [String], CGFloat)] = [("menu", menuSymbols, 15), ("tool", toolSymbols, 17)]
        for (context, names, nominal) in sets {
            for name in names {
                let resolved = MonknotSFSymbol.resolve(name, fallback: name == "link.badge.minus" ? "xmark" : "questionmark")
                let pointSize = MonknotSymbolOptics.pointSizeBase(for: resolved, nominal: nominal)
                if let icon = icon(resolved, pointSize: pointSize, weight: .regular) {
                    result["\(context):\(name)"] = icon
                }
            }
        }
        for name in smallSymbols {
            if let icon = icon(name, pointSize: MonknotMetrics.chevronPointSizeBase, weight: .semibold) {
                result["small:\(name)"] = icon
            }
        }
        cached = result
        return result
    }

    private static func icon(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> [String: Any]? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
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
