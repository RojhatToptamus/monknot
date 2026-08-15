import AppKit
import MonknotCore
import SwiftUI

struct MarkdownTextEditorCommandRequest: Equatable {
    let serial: Int
    let command: MarkdownTextEditorCommand
}

@MainActor
enum MonknotNativeMarkdownCommand {
    static var canCopyRenderedSelection: Bool {
        focusedMarkdownTextView?.selectedRange().length ?? 0 > 0
    }

    @discardableResult
    static func copyRenderedSelection() -> Bool {
        guard let textView = focusedMarkdownTextView else { return false }
        do {
            return try textView.copyRenderedMarkdown(to: .general)
        } catch {
            NSSound.beep()
            return false
        }
    }

    private static var focusedMarkdownTextView: MarkdownNSTextView? {
        NSApp.keyWindow?.firstResponder as? MarkdownNSTextView
    }
}

@MainActor
enum MonknotNativeSpellingCommand {
    static var canCheckDocument: Bool {
        guard let textView = focusedTextView else { return false }
        return writingToolsAreInactive(in: textView)
            && textView.flowWritingToolsInvocationEligible
    }

    @discardableResult
    static func checkSpelling() -> Bool {
        guard let textView = focusedTextView,
              writingToolsAreInactive(in: textView),
              textView.flowWritingToolsInvocationEligible
        else { return false }
        // Use the modern text-checking pipeline so the delegate can remove
        // Markdown-protected results before AppKit presents them.
        textView.checkTextInDocument(nil)
        return true
    }

    private static var focusedTextView: MarkdownNSTextView? {
        // A menu or the shared spelling panel can become the key window while the
        // document window remains main. Keep command validation anchored to the
        // document responder in that state.
        // https://developer.apple.com/documentation/appkit/nsapplication/mainwindow
        for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
            if let textView = window.firstResponder as? MarkdownNSTextView {
                return textView
            }
        }
        return nil
    }

    private static func writingToolsAreInactive(in textView: MarkdownNSTextView) -> Bool {
        if #available(macOS 15.0, *) {
            return !textView.isWritingToolsActive
        }
        return true
    }
}

@MainActor
enum MonknotNativeWritingToolsCommand {
    static var canShowWritingTools: Bool {
        guard #available(macOS 15.2, *),
              NSWritingToolsCoordinator.isWritingToolsAvailable,
              let textView = focusedTextView
        else { return false }
        return textView.flowSourceMode != nil
            && textView.isEditable
            && !textView.isWritingToolsActive
            && (!textView.flowWritingToolsReady || textView.flowWritingToolsInvocationEligible)
    }

    @discardableResult
    static func showWritingTools() -> Bool {
        guard #available(macOS 15.2, *),
              NSWritingToolsCoordinator.isWritingToolsAvailable,
              let textView = focusedTextView,
              !textView.isWritingToolsActive,
              textView.writingToolsRequestHandler?() == true
        else { return false }
        return true
    }

    private static var focusedTextView: MarkdownNSTextView? {
        NSApp.keyWindow?.firstResponder as? MarkdownNSTextView
    }
}

struct EditorTextCheckingOptions: Equatable {
    static let spellingPreferenceKey = "Monknot.checkSpellingWhileTyping"
    static let grammarPreferenceKey = "Monknot.checkGrammarWhileTyping"
    static let inlinePredictionsPreferenceKey = "Monknot.inlinePredictions"
    static let defaultChecksSpelling = true
    static let defaultChecksGrammar = true
    static let defaultInlinePredictions = true
    static let defaultValue = EditorTextCheckingOptions(
        checksSpelling: defaultChecksSpelling,
        checksGrammar: defaultChecksGrammar,
        inlinePredictions: defaultInlinePredictions
    )

    let checksSpelling: Bool
    let checksGrammar: Bool
    let inlinePredictions: Bool

    init(
        checksSpelling: Bool,
        checksGrammar: Bool,
        inlinePredictions: Bool = defaultInlinePredictions
    ) {
        self.checksSpelling = checksSpelling
        self.checksGrammar = checksGrammar
        self.inlinePredictions = inlinePredictions
    }
}

enum EditorFlowCheckingTypes {
    static func value(for options: EditorTextCheckingOptions) -> NSTextCheckingTypes {
        var types = NSTextCheckingResult.CheckingType.orthography.rawValue
        if options.checksSpelling {
            types |= NSTextCheckingResult.CheckingType.spelling.rawValue
            types |= NSTextCheckingResult.CheckingType.correction.rawValue
        }
        if options.checksGrammar {
            // The unified checker on macOS may omit grammar results unless the
            // spelling bit is present. Flow still filters spelling candidates
            // below when the user has disabled spelling suggestions.
            types |= NSTextCheckingResult.CheckingType.spelling.rawValue
            types |= NSTextCheckingResult.CheckingType.grammar.rawValue
        }
        return types
    }
}

enum EditorFlowCorrectionKind: Equatable {
    case spelling
    case grammar
}

struct EditorFlowCorrectionEdit: Equatable {
    let range: NSRange
    let originalText: String
    let replacementText: String
    let kind: EditorFlowCorrectionKind
}

struct EditorFlowSuggestion: Equatable {
    let documentID: String
    let revision: Int
    let selectedRange: NSRange
    let caretUTF16Offset: Int
    let edits: [EditorFlowCorrectionEdit]

    init(
        documentID: String,
        revision: Int,
        selectedRange: NSRange,
        caretUTF16Offset: Int,
        edits: [EditorFlowCorrectionEdit]
    ) {
        self.documentID = documentID
        self.revision = revision
        self.selectedRange = selectedRange
        self.caretUTF16Offset = caretUTF16Offset
        self.edits = edits.sorted { left, right in
            if left.range.location == right.range.location {
                return left.range.length < right.range.length
            }
            return left.range.location < right.range.location
        }
    }

    /// The exact changes the editor may apply. These strings are intentionally
    /// not compacted: any UI that can mutate text from a suggestion must first
    /// show every affected string in full or route through review.
    var fullChangeRows: [String] {
        edits.map { "\($0.originalText) → \($0.replacementText)" }
    }

    var exactChangeDescription: String {
        edits.map {
            "replace “\($0.originalText)” with “\($0.replacementText)”"
        }.joined(separator: ", ")
    }

    var accessibilityText: String {
        let instruction = "Tab to continue; Escape to dismiss."
        if edits.count == 1 {
            let description = exactChangeDescription
            return "\(description.prefix(1).uppercased())\(description.dropFirst()). \(instruction)"
        }
        return "Fix \(edits.count) clear issues: \(exactChangeDescription). \(instruction)"
    }

    func matches(
        documentID: String?,
        revision: Int,
        text: String,
        selectedRange: NSRange
    ) -> Bool {
        guard self.documentID == documentID,
              self.revision == revision,
              self.selectedRange == selectedRange,
              caretUTF16Offset == selectedRange.location + selectedRange.length,
              !edits.isEmpty
        else { return false }
        let source = text as NSString
        var previousUpperBound = -1
        for edit in edits {
            guard edit.range.location != NSNotFound,
                  edit.range.location >= 0,
                  edit.range.length > 0,
                  NSMaxRange(edit.range) <= source.length,
                  edit.range.location >= previousUpperBound,
                  source.substring(with: edit.range) == edit.originalText,
                  edit.originalText != edit.replacementText
            else { return false }
            previousUpperBound = NSMaxRange(edit.range)
        }
        return true
    }
}

struct EditorFlowCueLayout: Equatable {
    enum Mode: Equatable {
        case direct
        case review
    }

    let mode: Mode
    let rows: [String]
    let size: NSSize
    let rowHeight: CGFloat
    let horizontalInset: CGFloat
    let cornerRadius: CGFloat

    static func make(
        for suggestion: EditorFlowSuggestion,
        availableWidth: CGFloat,
        editorFont: NSFont,
        zoomScale: CGFloat
    ) -> EditorFlowCueLayout {
        let scale = max(0.1, zoomScale)
        let rowHeight = max(1, (30 * scale).rounded())
        let horizontalInset = max(1, (10 * scale).rounded())
        let cornerRadius = max(1, (12 * scale).rounded())
        let cueFont = shortcutFont(scale: scale)
        let hint = "  Tab"
        let hintWidth = ceil((hint as NSString).size(withAttributes: [.font: cueFont]).width)
        let maximumContentWidth = max(0, availableWidth - horizontalInset * 2)
        let changeRows = suggestion.fullChangeRows
        let joined = changeRows.joined(separator: " · ")

        let joinedWidth = width(of: joined, font: editorFont) + hintWidth
        if joinedWidth <= maximumContentWidth {
            return layout(
                mode: .direct,
                rows: [joined],
                contentWidth: joinedWidth,
                rowHeight: rowHeight,
                horizontalInset: horizontalInset,
                cornerRadius: cornerRadius
            )
        }

        let stackedWidths = changeRows.enumerated().map { index, row in
            width(of: row, font: editorFont) + (index == changeRows.count - 1 ? hintWidth : 0)
        }
        if let widest = stackedWidths.max(), widest <= maximumContentWidth {
            return layout(
                mode: .direct,
                rows: changeRows,
                contentWidth: widest,
                rowHeight: rowHeight,
                horizontalInset: horizontalInset,
                cornerRadius: cornerRadius
            )
        }

        let reviewCandidates = [
            "Review \(changeRows.count) \(changeRows.count == 1 ? "change" : "changes")",
            "Review \(changeRows.count)",
            "Review",
        ]
        let review = reviewCandidates.first {
            width(of: $0, font: editorFont) + hintWidth <= maximumContentWidth
        } ?? "Review"
        let reviewWidth = width(of: review, font: editorFont) + hintWidth
        return layout(
            mode: .review,
            rows: [review],
            contentWidth: min(maximumContentWidth, reviewWidth),
            rowHeight: rowHeight,
            horizontalInset: horizontalInset,
            cornerRadius: cornerRadius
        )
    }

    private static func layout(
        mode: Mode,
        rows: [String],
        contentWidth: CGFloat,
        rowHeight: CGFloat,
        horizontalInset: CGFloat,
        cornerRadius: CGFloat
    ) -> EditorFlowCueLayout {
        EditorFlowCueLayout(
            mode: mode,
            rows: rows,
            size: NSSize(
                width: ceil(contentWidth + horizontalInset * 2),
                height: rowHeight * CGFloat(max(1, rows.count))
            ),
            rowHeight: rowHeight,
            horizontalInset: horizontalInset,
            cornerRadius: cornerRadius
        )
    }

    private static func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func shortcutFont(scale: CGFloat) -> NSFont {
        let size = max(1, (12 * scale * 2).rounded() / 2)
        let base = NSFont.systemFont(ofSize: size, weight: .regular)
        return base.fontDescriptor.withDesign(.rounded).flatMap {
            NSFont(descriptor: $0, size: size)
        } ?? base
    }
}

private struct EditorFlowCuePalette {
    let surface: NSColor
    let primaryText: NSColor
    let secondaryText: NSColor
    let ring: NSColor
    let usesDarkElevation: Bool

    static let native = EditorFlowCuePalette(
        surface: .windowBackgroundColor,
        primaryText: .labelColor,
        secondaryText: .secondaryLabelColor,
        ring: .separatorColor,
        usesDarkElevation: false
    )
}

struct EditorFlowCheckSnapshot: Equatable {
    let documentID: String
    let revision: Int
    let checkedText: String
    let checkedRange: NSRange
    let selectedRange: NSRange
    let caretUTF16Offset: Int
    let options: EditorTextCheckingOptions
    let sourceMode: FlowSourceMode
    let offersSentenceBatch: Bool
    let checksCompletedStructuralSentence: Bool
}

struct EditorFlowCorrectionCandidate: Equatable {
    let range: NSRange
    let replacementText: String
    let kind: EditorFlowCorrectionKind
}

struct EditorFlowAmbiguousGrammarCandidate: Equatable {
    let range: NSRange
    let replacementTexts: [String]
}

enum EditorFlowCorrectionResolver {
    typealias SpellingCorrection = (_ range: NSRange, _ orthography: NSOrthography?) -> String?
    static let maximumValidatedGrammarAlternatives = 3

    static func concreteCorrections(
        in text: String,
        caretUTF16Offset: Int,
        results: [NSTextCheckingResult],
        orthography: NSOrthography?,
        spellingCorrection: SpellingCorrection
    ) -> [EditorFlowCorrectionCandidate] {
        let sourceLength = (text as NSString).length
        let candidates = results.flatMap { result -> [EditorFlowCorrectionCandidate] in
            guard result.range.location != NSNotFound,
                  result.range.location >= 0,
                  result.range.length > 0,
                  NSMaxRange(result.range) <= sourceLength,
                  NSMaxRange(result.range) <= caretUTF16Offset
            else { return [] }

            switch result.resultType {
            case .correction:
                guard let replacement = concreteReplacement(result.replacementString) else { return [] }
                return [.init(range: result.range, replacementText: replacement, kind: .spelling)]
            case .spelling:
                guard let replacement = concreteReplacement(
                    spellingCorrection(result.range, orthography)
                ) else { return [] }
                return [.init(range: result.range, replacementText: replacement, kind: .spelling)]
            case .grammar:
                return grammarCandidates(from: result, sourceLength: sourceLength)
            default:
                return []
            }
        }

        return candidates
            .filter { candidate in
                let original = (text as NSString).substring(with: candidate.range)
                return original != candidate.replacementText
            }
            .sorted { left, right in
                if left.range.location == right.range.location {
                    if left.range.length == right.range.length {
                        return left.replacementText < right.replacementText
                    }
                    return left.range.length < right.range.length
                }
                return left.range.location < right.range.location
            }
            .reduce(into: []) { unique, candidate in
                if let last = unique.last,
                   last.range == candidate.range,
                   last.replacementText == candidate.replacementText,
                   last.kind == candidate.kind {
                    return
                }
                unique.append(candidate)
            }
    }

    static func ambiguousGrammarCorrections(
        in text: String,
        caretUTF16Offset: Int,
        results: [NSTextCheckingResult]
    ) -> [EditorFlowAmbiguousGrammarCandidate] {
        let source = text as NSString
        return results.flatMap { result -> [EditorFlowAmbiguousGrammarCandidate] in
            guard result.resultType == .grammar,
                  result.range.location != NSNotFound,
                  result.range.location >= 0,
                  result.range.length > 0,
                  NSMaxRange(result.range) <= source.length,
                  NSMaxRange(result.range) <= caretUTF16Offset
            else { return [] }

            return (result.grammarDetails ?? []).compactMap { detail in
                guard let corrections = detail[NSGrammarCorrections] as? [String] else {
                    return nil
                }
                var uniqueReplacements: [String] = []
                for correction in corrections {
                    guard let replacement = concreteReplacement(correction),
                          !uniqueReplacements.contains(replacement)
                    else { continue }
                    uniqueReplacements.append(replacement)
                }
                guard uniqueReplacements.count > 1,
                      uniqueReplacements.count <= maximumValidatedGrammarAlternatives,
                      let range = grammarRange(
                        from: detail,
                        resultRange: result.range,
                        sourceLength: source.length
                      ),
                      NSMaxRange(range) <= caretUTF16Offset
                else { return nil }
                let original = source.substring(with: range)
                let replacements = uniqueReplacements.filter { $0 != original }
                guard replacements.count > 1 else { return nil }
                return EditorFlowAmbiguousGrammarCandidate(
                    range: range,
                    replacementTexts: replacements
                )
            }
        }
    }

    private static func grammarCandidates(
        from result: NSTextCheckingResult,
        sourceLength: Int
    ) -> [EditorFlowCorrectionCandidate] {
        (result.grammarDetails ?? []).compactMap { detail in
            guard let corrections = detail[NSGrammarCorrections] as? [String],
                  corrections.count == 1,
                  let replacement = concreteReplacement(corrections[0])
            else { return nil }

            guard let range = grammarRange(
                from: detail,
                resultRange: result.range,
                sourceLength: sourceLength
            ) else { return nil }
            return .init(range: range, replacementText: replacement, kind: .grammar)
        }
    }

    private static func grammarRange(
        from detail: [String: Any],
        resultRange: NSRange,
        sourceLength: Int
    ) -> NSRange? {
        let range: NSRange
        if let value = detail[NSGrammarRange] as? NSValue {
            let relativeRange = value.rangeValue
            guard relativeRange.location != NSNotFound,
                  relativeRange.location >= 0,
                  relativeRange.length > 0,
                  NSMaxRange(relativeRange) <= resultRange.length
            else { return nil }
            range = NSRange(
                location: resultRange.location + relativeRange.location,
                length: relativeRange.length
            )
        } else {
            range = resultRange
        }

        guard range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= sourceLength
        else { return nil }
        return range
    }

    private static func concreteReplacement(_ replacement: String?) -> String? {
        guard let replacement, !replacement.isEmpty else { return nil }
        return replacement
    }
}

enum EditorFlowCheckPlanner {
    static let boundaryDelayNanoseconds: UInt64 = 260_000_000
    static let idleDelayNanoseconds: UInt64 = 560_000_000
    private static let maximumCheckedUTF16Length = 900

    struct Plan: Equatable {
        let range: NSRange
        let delayNanoseconds: UInt64
        let offersSentenceBatch: Bool
    }

    static func plan(in text: String, selectedRange: NSRange) -> Plan? {
        let source = text as NSString
        let caret = selectedRange.location + selectedRange.length
        guard selectedRange.length == 0,
              caret > 0,
              caret <= source.length
        else { return nil }

        let paragraphRange = source.paragraphRange(for: NSRange(location: caret - 1, length: 0))
        let paragraphStart = paragraphRange.location
        var candidateStart = max(paragraphStart, caret - maximumCheckedUTF16Length)
        if candidateStart > paragraphStart {
            let composedRange = source.rangeOfComposedCharacterSequence(at: candidateStart)
            candidateStart = composedRange.location < candidateStart
                ? NSMaxRange(composedRange)
                : candidateStart
            while candidateStart < caret {
                guard let scalar = UnicodeScalar(source.character(at: candidateStart)),
                      !CharacterSet.whitespacesAndNewlines.contains(scalar),
                      !CharacterSet.punctuationCharacters.contains(scalar)
                else { break }
                candidateStart = NSMaxRange(source.rangeOfComposedCharacterSequence(
                    at: candidateStart
                ))
            }
            while candidateStart < caret,
                  let scalar = UnicodeScalar(source.character(at: candidateStart)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                candidateStart += 1
            }
        }
        let boundedRange = NSRange(location: candidateStart, length: caret - candidateStart)
        let range = latestSentenceRange(in: source, boundedRange: boundedRange)
        guard range.length > 0 else { return nil }

        let precedingCharacter = UnicodeScalar(source.character(at: caret - 1))
        let isBoundary = precedingCharacter.map {
            CharacterSet.whitespacesAndNewlines.contains($0) ||
                CharacterSet.punctuationCharacters.contains($0)
        } ?? false
        return Plan(
            range: range,
            delayNanoseconds: isBoundary ? boundaryDelayNanoseconds : idleDelayNanoseconds,
            offersSentenceBatch: endsAtSentenceBoundary(source, caret: caret)
        )
    }

    private static func latestSentenceRange(
        in source: NSString,
        boundedRange: NSRange
    ) -> NSRange {
        let excerpt = source.substring(with: boundedRange)
        let excerptNSString = excerpt as NSString
        var probe = excerptNSString.length - 1
        while probe >= 0,
              let scalar = UnicodeScalar(excerptNSString.character(at: probe)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            probe -= 1
        }
        guard probe >= 0 else { return boundedRange }

        var latest = NSRange(location: 0, length: excerptNSString.length)
        excerpt.enumerateSubstrings(
            in: excerpt.startIndex..<excerpt.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, substringRange, _, stop in
            let localRange = NSRange(substringRange, in: excerpt)
            if probe >= localRange.location && probe < NSMaxRange(localRange) {
                latest = localRange
                stop = true
            }
        }
        return NSRange(
            location: boundedRange.location + latest.location,
            length: latest.length
        )
    }

    private static func endsAtSentenceBoundary(_ source: NSString, caret: Int) -> Bool {
        guard caret > 0 else { return false }
        var index = caret - 1
        var crossedNewline = false
        while index >= 0,
              let scalar = UnicodeScalar(source.character(at: index)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            crossedNewline = crossedNewline || CharacterSet.newlines.contains(scalar)
            index -= 1
        }
        if crossedNewline { return true }
        guard index >= 0, let scalar = UnicodeScalar(source.character(at: index)) else {
            return false
        }
        return ".!?。！？".unicodeScalars.contains(scalar)
    }
}

struct EditorFlowCheckingClient {
    typealias Completion = ([NSTextCheckingResult], NSOrthography?) -> Void
    let request: (
        _ text: String,
        _ range: NSRange,
        _ checkingTypes: NSTextCheckingTypes,
        _ documentTag: Int,
        _ completion: @escaping Completion
    ) -> Void

    static let system = EditorFlowCheckingClient { text, range, checkingTypes, documentTag, completion in
        NSSpellChecker.shared.requestChecking(
            of: text,
            range: range,
            types: checkingTypes,
            options: nil,
            inSpellDocumentWithTag: documentTag
        ) { _, results, orthography, _ in
            completion(results, orthography)
        }
    }
}

enum MarkdownTextEditorCommand: Equatable {
    case paragraph
    case heading(level: Int)
    case bold
    case italic
    case quote
    case code
    case link
    case bulletList
    case numberedList
    case taskList
    case image
    case horizontalRule
}

struct MarkdownEditorSelectionSnapshot: Equatable {
    let documentID: String
    let revision: Int
    let selectedRange: NSRange
    let selectedMarkdown: String

    var caretUTF16Offset: Int {
        selectedRange.location + selectedRange.length
    }
}

struct MarkdownEditorLinkRequest: Equatable {
    let documentID: String
    let revision: Int
    let link: MarkdownWorkspaceLink
}

struct MarkdownImagePasteRequest {
    let documentID: String
    let revision: Int
    let sourceText: String
    let selectedRange: NSRange
    let image: NSImage
    private let insertion: (String) -> Bool

    init(
        documentID: String,
        revision: Int,
        sourceText: String,
        selectedRange: NSRange,
        image: NSImage,
        insertion: @escaping (String) -> Bool
    ) {
        self.documentID = documentID
        self.revision = revision
        self.sourceText = sourceText
        self.selectedRange = selectedRange
        self.image = image
        self.insertion = insertion
    }

    @MainActor
    @discardableResult
    func insertMarkdown(_ markdown: String) -> Bool {
        insertion(markdown)
    }
}

struct MarkdownFileDropRequest {
    let documentID: String
    let revision: Int
    let sourceText: String
    let insertionRange: NSRange
    let urls: [URL]
    private let insertion: (String) -> Bool

    init(
        documentID: String,
        revision: Int,
        sourceText: String,
        insertionRange: NSRange,
        urls: [URL],
        insertion: @escaping (String) -> Bool
    ) {
        self.documentID = documentID
        self.revision = revision
        self.sourceText = sourceText
        self.insertionRange = insertionRange
        self.urls = urls
        self.insertion = insertion
    }

    @MainActor
    @discardableResult
    func insertMarkdown(_ markdown: String) -> Bool {
        insertion(markdown)
    }
}

struct MarkdownTextEditor: NSViewRepresentable {
    let documentID: String
    @Binding var text: String
    let theme: AppTheme
    let fontSize: CGFloat
    let zoomScale: Double
    let contentWidthPercent: Double
    let fontSmoothing: Bool
    let textCheckingOptions: EditorTextCheckingOptions
    let scrollPosition: DocumentScrollPosition?
    let textSelection: DocumentTextSelection?
    let syncScrollEnabled: Bool
    let syncScrollTargetLine: Int?
    @Binding var sourceLocation: MarkdownSourceLocation?
    @Binding var searchState: DocumentSearchState
    let searchOptions: MonknotSearchOptions
    let onScrollPositionChange: (DocumentScrollPosition) -> Void
    let onVisibleTopLineChange: ((Int) -> Void)?
    let commandRequest: MarkdownTextEditorCommandRequest?
    let markdownShortcutsEnabled: Bool
    let flowSourceMode: FlowSourceMode?
    let wikilinkDocuments: [WorkspaceDocument]
    let onSelectionChange: ((MarkdownEditorSelectionSnapshot) -> Void)?
    let onOpenLink: ((MarkdownEditorLinkRequest) -> Void)?
    let onInspectLinks: (() -> Void)?
    let onImagePasteRequest: ((MarkdownImagePasteRequest) -> Void)?
    let onFileDropRequest: ((MarkdownFileDropRequest) -> Void)?
    let onWritingToolsTextCommit: ((String, String) -> Void)?
    let onWritingToolsStateChange: ((String, Bool) -> Bool)?

    init(
        documentID: String,
        text: Binding<String>,
        theme: AppTheme,
        fontSize: CGFloat,
        zoomScale: Double,
        contentWidthPercent: Double,
        fontSmoothing: Bool,
        textCheckingOptions: EditorTextCheckingOptions = .defaultValue,
        scrollPosition: DocumentScrollPosition?,
        textSelection: DocumentTextSelection? = nil,
        sourceLocation: Binding<MarkdownSourceLocation?>,
        searchState: Binding<DocumentSearchState>,
        searchOptions: MonknotSearchOptions = MonknotSearchOptions(),
        onScrollPositionChange: @escaping (DocumentScrollPosition) -> Void,
        syncScrollEnabled: Bool = false,
        syncScrollTargetLine: Int? = nil,
        onVisibleTopLineChange: ((Int) -> Void)? = nil,
        commandRequest: MarkdownTextEditorCommandRequest? = nil,
        markdownShortcutsEnabled: Bool = false,
        flowSourceMode: FlowSourceMode? = nil,
        wikilinkDocuments: [WorkspaceDocument] = [],
        onSelectionChange: ((MarkdownEditorSelectionSnapshot) -> Void)? = nil,
        onOpenLink: ((MarkdownEditorLinkRequest) -> Void)? = nil,
        onInspectLinks: (() -> Void)? = nil,
        onImagePasteRequest: ((MarkdownImagePasteRequest) -> Void)? = nil,
        onFileDropRequest: ((MarkdownFileDropRequest) -> Void)? = nil,
        onWritingToolsTextCommit: ((String, String) -> Void)? = nil,
        onWritingToolsStateChange: ((String, Bool) -> Bool)? = nil
    ) {
        self.documentID = documentID
        self._text = text
        self.theme = theme
        self.fontSize = fontSize
        self.zoomScale = zoomScale
        self.contentWidthPercent = contentWidthPercent
        self.fontSmoothing = fontSmoothing
        self.textCheckingOptions = textCheckingOptions
        self.scrollPosition = scrollPosition
        self.textSelection = textSelection
        self.syncScrollEnabled = syncScrollEnabled
        self.syncScrollTargetLine = syncScrollTargetLine
        self._sourceLocation = sourceLocation
        self._searchState = searchState
        self.searchOptions = searchOptions
        self.onScrollPositionChange = onScrollPositionChange
        self.onVisibleTopLineChange = onVisibleTopLineChange
        self.commandRequest = commandRequest
        self.markdownShortcutsEnabled = markdownShortcutsEnabled
        self.flowSourceMode = flowSourceMode
        self.wikilinkDocuments = wikilinkDocuments
        self.onSelectionChange = onSelectionChange
        self.onOpenLink = onOpenLink
        self.onInspectLinks = onInspectLinks
        self.onImagePasteRequest = onImagePasteRequest
        self.onFileDropRequest = onFileDropRequest
        self.onWritingToolsTextCommit = onWritingToolsTextCommit
        self.onWritingToolsStateChange = onWritingToolsStateChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        MonknotScrollbarStyle.apply(to: scrollView)

        let textView = MarkdownNSTextView()
        textView.identifier = .monknotDocumentFocusTarget
        textView.fontSmoothingEnabled = fontSmoothing
        textView.delegate = context.coordinator
        textView.markdownShortcutsEnabled = markdownShortcutsEnabled
        textView.flowSourceMode = flowSourceMode
        textView.commandHandler = { [weak coordinator = context.coordinator] command in
            coordinator?.apply(command) ?? false
        }
        textView.workspaceLinkHandler = { [weak coordinator = context.coordinator] link in
            coordinator?.open(link) ?? false
        }
        textView.inspectLinksHandler = onInspectLinks
        textView.imagePasteHandler = { [weak coordinator = context.coordinator] image in
            coordinator?.requestImagePaste(image) ?? false
        }
        textView.fileDropHandler = onFileDropRequest == nil ? nil : { [weak coordinator = context.coordinator] urls, offset in
            coordinator?.requestFileDrop(urls, atUTF16Offset: offset) ?? false
        }
        textView.flowSuggestionAcceptanceHandler = { [weak coordinator = context.coordinator] suggestion in
            coordinator?.acceptFlowSuggestion(suggestion) ?? false
        }
        textView.flowSuggestionDismissalHandler = { [weak coordinator = context.coordinator] in
            coordinator?.dismissFlowSuggestion()
        }
        textView.flowSuggestionCancellationHandler = { [weak coordinator = context.coordinator] in
            coordinator?.cancelFlowForFocusLoss()
        }
        textView.writingToolsRequestHandler = { [weak coordinator = context.coordinator] in
            coordinator?.requestWritingTools() ?? false
        }
        textView.updateDragTypeRegistration()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.applyTextChecking(textCheckingOptions)
        textView.applyWritingTools(flowSourceMode, protectedRangesReady: false)
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.zoomScale = zoomScale
        textView.contentWidthPercent = contentWidthPercent
        textView.refreshContentWidthLayout()
        let resolvedFont = font(for: theme, size: fontSize)
        textView.font = resolvedFont
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.documentID = documentID
        context.coordinator.onScrollPositionChange = onScrollPositionChange
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.onImagePasteRequest = onImagePasteRequest
        context.coordinator.onFileDropRequest = onFileDropRequest
        context.coordinator.onWritingToolsTextCommit = onWritingToolsTextCommit
        context.coordinator.onWritingToolsStateChange = onWritingToolsStateChange
        context.coordinator.configureFlow(mode: flowSourceMode, options: textCheckingOptions)
        context.coordinator.attach(to: scrollView)
        applyTheme(theme, to: textView, in: scrollView)
        context.coordinator.markFontApplied(resolvedFont)
        context.coordinator.markThemeApplied(theme)
        context.coordinator.markFontSmoothingApplied(fontSmoothing)
        context.coordinator.markMarkdownShortcutsApplied(markdownShortcutsEnabled)
        context.coordinator.applySyntaxHighlighting(
            enabled: markdownShortcutsEnabled,
            theme: theme,
            font: resolvedFont,
            in: textView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let didChangeDocument = context.coordinator.prepareForDocument(documentID, in: scrollView)
        context.coordinator.onScrollPositionChange = onScrollPositionChange
        context.coordinator.onVisibleTopLineChange = onVisibleTopLineChange
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.onImagePasteRequest = onImagePasteRequest
        context.coordinator.onFileDropRequest = onFileDropRequest
        context.coordinator.onWritingToolsTextCommit = onWritingToolsTextCommit
        context.coordinator.onWritingToolsStateChange = onWritingToolsStateChange
        textView.flowSourceMode = flowSourceMode
        context.coordinator.configureFlow(mode: flowSourceMode, options: textCheckingOptions)
        textView.inspectLinksHandler = onInspectLinks
        textView.fileDropHandler = onFileDropRequest == nil ? nil : { [weak coordinator = context.coordinator] urls, offset in
            coordinator?.requestFileDrop(urls, atUTF16Offset: offset) ?? false
        }
        textView.updateDragTypeRegistration()
        context.coordinator.syncScrollEnabled = syncScrollEnabled
        let visibleOrigin = scrollView.contentView.bounds.origin

        if !context.coordinator.isWritingToolsActive, textView.string != text {
            let selectedRanges = didChangeDocument ? [] : textView.selectedRanges
            textView.string = text
            if selectedRanges.isEmpty {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            } else {
                textView.selectedRanges = selectedRanges
            }
            context.coordinator.externalTextDidChange()
        }
        if context.coordinator.isWritingToolsActive {
            if let commandRequest {
                context.coordinator.apply(commandRequest)
            }
            return
        }
        context.coordinator.restoreSelectionIfNeeded(textSelection, in: textView)

        let resolvedFont = font(for: theme, size: fontSize)
        if context.coordinator.shouldApplyFont(resolvedFont) {
            textView.font = resolvedFont
        }
        textView.zoomScale = zoomScale
        textView.contentWidthPercent = contentWidthPercent
        if context.coordinator.shouldApplyFontSmoothing(fontSmoothing) {
            textView.fontSmoothingEnabled = fontSmoothing
        }
        textView.applyTextChecking(textCheckingOptions)
        context.coordinator.refreshNativeFlowAvailability()
        if context.coordinator.shouldApplyMarkdownShortcuts(markdownShortcutsEnabled) {
            textView.markdownShortcutsEnabled = markdownShortcutsEnabled
        }
        textView.wikilinkDocuments = wikilinkDocuments
        if context.coordinator.shouldApplyTheme(theme) {
            applyTheme(theme, to: textView, in: scrollView)
        }

        if let commandRequest {
            context.coordinator.apply(commandRequest)
        }

        context.coordinator.applySyntaxHighlighting(
            enabled: markdownShortcutsEnabled,
            theme: theme,
            font: resolvedFont,
            in: textView
        )

        if didChangeDocument {
            context.coordinator.restoreScrollPosition(scrollPosition?.point ?? .zero, in: scrollView)
        } else {
            context.coordinator.restoreScrollPosition(visibleOrigin, in: scrollView, shouldPublish: false)
        }

        if let sourceLocation {
            context.coordinator.navigate(to: sourceLocation, in: textView)
            DispatchQueue.main.async {
                self.sourceLocation = nil
            }
        }

        context.coordinator.applySyncScrollTargetLine(syncScrollTargetLine, in: textView, scrollView: scrollView)

        let searchResult = context.coordinator.applySearch(
            searchState,
            options: searchOptions,
            theme: theme,
            in: textView
        )
        if DocumentSearchResult(
            currentIndex: searchState.currentIndex,
            totalCount: searchState.totalCount
        ) != searchResult {
            DispatchQueue.main.async {
                self.searchState.updateResult(searchResult)
            }
        }
        context.coordinator.publishSelection()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.publishCurrentScrollPosition()
        coordinator.publishSelection()
        coordinator.detach()
        coordinator.textView?.delegate = nil
        coordinator.textView?.commandHandler = nil
        coordinator.textView?.workspaceLinkHandler = nil
        coordinator.textView?.inspectLinksHandler = nil
        coordinator.textView?.imagePasteHandler = nil
        coordinator.textView?.fileDropHandler = nil
        coordinator.textView?.flowSuggestionAcceptanceHandler = nil
        coordinator.textView?.flowSuggestionDismissalHandler = nil
        coordinator.textView?.flowSuggestionCancellationHandler = nil
        coordinator.textView?.writingToolsRequestHandler = nil
        coordinator.cancelFlowSuggestion()
        coordinator.textView = nil
    }

    private func applyTheme(_ theme: AppTheme, to textView: MarkdownNSTextView, in scrollView: NSScrollView) {
        let background = NSColor(hex: theme.background)
        textView.backgroundColor = background
        scrollView.backgroundColor = background
        textView.textColor = NSColor(hex: theme.foreground)
        textView.insertionPointColor = NSColor(hex: theme.cursor)
        textView.flowCuePalette = EditorFlowCuePalette(
            surface: NSColor(theme.elevatedSurfaceColor),
            primaryText: NSColor(theme.foregroundColor),
            secondaryText: NSColor(theme.mutedForegroundColor),
            ring: NSColor(theme.foregroundColor).withAlphaComponent(theme.isDark ? 0.14 : 0.08),
            usesDarkElevation: theme.isDark
        )
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(hex: theme.selectionBackground),
            .foregroundColor: NSColor(hex: theme.selectionForeground)
        ]
    }

    private func font(for theme: AppTheme, size: CGFloat) -> NSFont {
        if let codeFontName = theme.codeFontName, let font = NSFont(name: codeFontName, size: size) {
            return font
        }

        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        private let flowCheckingClient: EditorFlowCheckingClient
        private let flowFocusValidator: (MarkdownNSTextView) -> Bool
        private let protectedRangeProvider: @Sendable (String, FlowSourceMode) -> [NSRange]
        private let writingToolsAvailability: () -> Bool
        private let writingToolsPresenter: (MarkdownNSTextView) -> Void
        weak var textView: MarkdownNSTextView?
        var documentID: String?
        var onScrollPositionChange: (DocumentScrollPosition) -> Void = { _ in }
        var onVisibleTopLineChange: ((Int) -> Void)?
        var onSelectionChange: ((MarkdownEditorSelectionSnapshot) -> Void)?
        var onOpenLink: ((MarkdownEditorLinkRequest) -> Void)?
        var onImagePasteRequest: ((MarkdownImagePasteRequest) -> Void)?
        var onFileDropRequest: ((MarkdownFileDropRequest) -> Void)?
        var onWritingToolsTextCommit: ((String, String) -> Void)?
        var onWritingToolsStateChange: ((String, Bool) -> Bool)?
        var syncScrollEnabled = false
        private var lastNavigatedLocation: MarkdownSourceLocation?
        private var searchMatches: [NSRange] = []
        private var highlightedRanges: [NSRange] = []
        private var lastSearchQuery = ""
        private var lastSearchOptions = MonknotSearchOptions()
        private var lastSearchedText = ""
        private var lastNavigationSerial = 0
        private var currentMatchIndex = 0
        private var lastHighlightTheme: SearchHighlightTheme?
        private weak var scrollView: NSScrollView?
        private var lastPublishedScrollPosition: DocumentScrollPosition?
        private var lastPublishedTopLine: Int?
        private var lastAppliedSyncScrollLine: Int?
        private var isRestoringScrollPosition = false
        private var lastCommandSerial = 0
        private var lastAppliedFontName: String?
        private var lastAppliedFontSize: CGFloat?
        private var lastAppliedTheme: AppTheme?
        private var lastAppliedFontSmoothing: Bool?
        private var lastAppliedMarkdownShortcuts: Bool?
        private var lastSyntaxText: String?
        private var lastSyntaxTheme: AppTheme?
        private var lastSyntaxFontName: String?
        private var lastSyntaxFontSize: CGFloat?
        private var lastSyntaxEnabled: Bool?
        private(set) var revision = 0
        private var lastPublishedSelection: MarkdownEditorSelectionSnapshot?
        private var shouldRestoreSelection = true
        private var flowSourceMode: FlowSourceMode?
        private var flowCheckingOptions = EditorTextCheckingOptions.defaultValue
        private var flowCheckTask: Task<Void, Never>?
        private var flowRequestToken = 0
        private struct PendingFlowProtectedRangesRetry {
            let snapshot: EditorFlowCheckSnapshot
            let token: Int
        }
        private var pendingFlowProtectedRangesRetry: PendingFlowProtectedRangesRetry?
        private struct ProtectedRangesSnapshot {
            let revision: Int
            let text: String
            let mode: FlowSourceMode
            let ranges: [NSRange]
        }
        private struct InlinePredictionEditCandidate {
            let sourceRevision: Int
            let sourceUTF16Length: Int
            let insertedRange: NSRange
            let insertedText: String
            let precedingContext: String
            let followingContext: String
            let resultingSelection: NSRange
        }
        private struct InlinePredictionContinuation {
            let revision: Int
            let utf16Length: Int
            let selection: NSRange
        }
        private struct PendingWritingToolsRangeUpdate {
            let expectedUTF16Length: Int
            let ranges: [NSRange]?
        }
        private struct PendingWritingToolsRequest {
            let documentID: String
            let revision: Int
            let selectedRange: NSRange
        }
        private struct SuppressedFlowSuggestion {
            struct Anchor {
                let range: NSRange
                let text: String
            }

            let documentID: String
            let edits: [EditorFlowCorrectionEdit]
            let acceptedAnchors: [Anchor]?

            init(_ suggestion: EditorFlowSuggestion, accepted: Bool) {
                documentID = suggestion.documentID
                edits = suggestion.edits
                guard accepted else {
                    acceptedAnchors = nil
                    return
                }
                var delta = 0
                acceptedAnchors = suggestion.edits.map { edit in
                    let replacementLength = (edit.replacementText as NSString).length
                    let anchor = Anchor(
                        range: NSRange(
                            location: edit.range.location + delta,
                            length: replacementLength
                        ),
                        text: edit.replacementText
                    )
                    delta += replacementLength - edit.range.length
                    return anchor
                }
            }

            func suppresses(_ candidateEdit: EditorFlowCorrectionEdit) -> Bool {
                edits.contains {
                    $0.range == candidateEdit.range
                        && $0.originalText == candidateEdit.originalText
                        && $0.replacementText == candidateEdit.replacementText
                }
            }

            func targetStillExists(in text: String) -> Bool {
                let source = text as NSString
                let originalStillExists = edits.allSatisfy {
                    $0.range.location >= 0
                        && NSMaxRange($0.range) <= source.length
                        && source.substring(with: $0.range) == $0.originalText
                }
                if originalStillExists { return true }
                guard let acceptedAnchors,
                      acceptedAnchors.allSatisfy({
                    $0.range.location >= 0
                        && NSMaxRange($0.range) <= source.length
                        && source.substring(with: $0.range) == $0.text
                })
                else { return false }
                return true
            }
        }
        private var protectedRangesSnapshot: ProtectedRangesSnapshot?
        private var protectedRangesTask: Task<Void, Never>?
        private var protectedRangesGeneration = 0
        private var pendingInlinePredictionEdit: InlinePredictionEditCandidate?
        private var inlinePredictionContinuation: InlinePredictionContinuation?
        private var writingToolsDocumentID: String?
        private var writingToolsProtectedRanges: [NSRange]?
        private var pendingWritingToolsRangeUpdate: PendingWritingToolsRangeUpdate?
        private var pendingWritingToolsRequest: PendingWritingToolsRequest?
        private var suppressedFlowSuggestion: SuppressedFlowSuggestion?
        var isWritingToolsActive: Bool { writingToolsDocumentID != nil }

        init(
            text: Binding<String>,
            flowCheckingClient: EditorFlowCheckingClient = .system,
            protectedRangeProvider: @escaping @Sendable (String, FlowSourceMode) -> [NSRange] = { text, mode in
                FlowProtectedRangeService().protectedRanges(in: text, mode: mode)
            },
            flowFocusValidator: @escaping (MarkdownNSTextView) -> Bool = { textView in
                guard let window = textView.window else { return false }
                return window.isKeyWindow && window.firstResponder === textView
            },
            writingToolsAvailability: @escaping () -> Bool = {
                guard #available(macOS 15.2, *) else { return false }
                return NSWritingToolsCoordinator.isWritingToolsAvailable
            },
            writingToolsPresenter: @escaping (MarkdownNSTextView) -> Void = { textView in
                guard #available(macOS 15.2, *) else { return }
                textView.showWritingTools(nil)
            }
        ) {
            self._text = text
            self.flowCheckingClient = flowCheckingClient
            self.protectedRangeProvider = protectedRangeProvider
            self.flowFocusValidator = flowFocusValidator
            self.writingToolsAvailability = writingToolsAvailability
            self.writingToolsPresenter = writingToolsPresenter
        }

        func attach(to scrollView: NSScrollView) {
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidResignActive(_:)),
                name: NSApplication.didResignActiveNotification,
                object: NSApp
            )
        }

        func detach() {
            finishWritingToolsSessionIfNeeded()
            cancelFlowSuggestion()
            protectedRangesTask?.cancel()
            protectedRangesTask = nil
            protectedRangesSnapshot = nil
            pendingInlinePredictionEdit = nil
            inlinePredictionContinuation = nil
            pendingWritingToolsRequest = nil
            suppressedFlowSuggestion = nil
            NotificationCenter.default.removeObserver(self)
            scrollView = nil
            onSelectionChange = nil
            onOpenLink = nil
            onImagePasteRequest = nil
            onFileDropRequest = nil
            onWritingToolsTextCommit = nil
            onWritingToolsStateChange = nil
        }

        func configureFlow(mode: FlowSourceMode?, options: EditorTextCheckingOptions) {
            guard flowSourceMode != mode || flowCheckingOptions != options else {
                refreshNativeFlowAvailability()
                return
            }
            pendingInlinePredictionEdit = nil
            inlinePredictionContinuation = nil
            pendingWritingToolsRequest = nil
            suppressedFlowSuggestion = nil
            flowSourceMode = mode
            flowCheckingOptions = options
            cancelFlowSuggestion()
            scheduleProtectedRangesRefresh(delayNanoseconds: 0)
            refreshNativeFlowAvailability()
            if mode == nil {
                finishWritingToolsSessionIfNeeded()
            }
        }

        func markFontApplied(_ font: NSFont) {
            lastAppliedFontName = font.fontName
            lastAppliedFontSize = font.pointSize
        }

        func shouldApplyFont(_ font: NSFont) -> Bool {
            let shouldApply = lastAppliedFontName != font.fontName ||
                abs((lastAppliedFontSize ?? -1) - font.pointSize) > 0.001
            guard shouldApply else { return false }
            markFontApplied(font)
            return true
        }

        func markThemeApplied(_ theme: AppTheme) {
            lastAppliedTheme = theme
        }

        func shouldApplyTheme(_ theme: AppTheme) -> Bool {
            guard lastAppliedTheme != theme else { return false }
            markThemeApplied(theme)
            return true
        }

        func markFontSmoothingApplied(_ enabled: Bool) {
            lastAppliedFontSmoothing = enabled
        }

        func shouldApplyFontSmoothing(_ enabled: Bool) -> Bool {
            guard lastAppliedFontSmoothing != enabled else { return false }
            markFontSmoothingApplied(enabled)
            return true
        }

        func markMarkdownShortcutsApplied(_ enabled: Bool) {
            lastAppliedMarkdownShortcuts = enabled
        }

        func shouldApplyMarkdownShortcuts(_ enabled: Bool) -> Bool {
            guard lastAppliedMarkdownShortcuts != enabled else { return false }
            markMarkdownShortcutsApplied(enabled)
            return true
        }

        func prepareForDocument(_ nextDocumentID: String, in scrollView: NSScrollView) -> Bool {
            self.scrollView = scrollView
            guard documentID != nextDocumentID else { return false }

            finishWritingToolsSessionIfNeeded()
            cancelFlowSuggestion()
            publishCurrentScrollPosition()
            publishSelection()
            documentID = nextDocumentID
            revision += 1
            pendingInlinePredictionEdit = nil
            inlinePredictionContinuation = nil
            pendingWritingToolsRequest = nil
            suppressedFlowSuggestion = nil
            scheduleProtectedRangesRefresh(delayNanoseconds: 0)
            lastPublishedSelection = nil
            shouldRestoreSelection = true
            lastPublishedScrollPosition = nil
            lastSyntaxText = nil
            return true
        }

        func externalTextDidChange() {
            cancelFlowSuggestion()
            pendingWritingToolsRequest = nil
            revision += 1
            pendingInlinePredictionEdit = nil
            inlinePredictionContinuation = nil
            refreshSuppressedFlowSuggestion()
            scheduleProtectedRangesRefresh()
            refreshNativeFlowAvailability()
        }

        func restoreSelectionIfNeeded(
            _ selection: DocumentTextSelection?,
            in textView: NSTextView
        ) {
            guard !isWritingToolsActive, shouldRestoreSelection else { return }
            shouldRestoreSelection = false
            let requestedRange = NSRange(
                location: selection?.location ?? 0,
                length: selection?.length ?? 0
            )
            let range = Self.boundedRange(requestedRange, in: textView.string)
            guard textView.selectedRange() != range else {
                publishSelection()
                return
            }
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            lastPublishedSelection = nil
            publishSelection()
        }
        func applySyntaxHighlighting(
            enabled: Bool,
            theme: AppTheme,
            font: NSFont,
            in textView: NSTextView
        ) {
            guard !isWritingToolsActive else { return }
            let source = textView.string
            guard lastSyntaxText != source ||
                    lastSyntaxTheme != theme ||
                    lastSyntaxFontName != font.fontName ||
                    abs((lastSyntaxFontSize ?? -1) - font.pointSize) > 0.001 ||
                    lastSyntaxEnabled != enabled
            else { return }

            MarkdownSyntaxHighlighter.apply(
                source,
                enabled: enabled,
                theme: theme,
                font: font,
                to: textView
            )
            lastSyntaxText = source
            lastSyntaxTheme = theme
            lastSyntaxFontName = font.fontName
            lastSyntaxFontSize = font.pointSize
            lastSyntaxEnabled = enabled
        }

        func applySyncScrollTargetLine(_ line: Int?, in textView: NSTextView, scrollView: NSScrollView) {
            guard !isWritingToolsActive,
                  syncScrollEnabled,
                  let line,
                  line > 0,
                  line != lastAppliedSyncScrollLine
            else { return }

            lastAppliedSyncScrollLine = line
            let offset = MarkdownScrollSync.characterOffset(forLine: line, in: textView.string)
            let range = NSRange(location: offset, length: 0)
            isRestoringScrollPosition = true
            textView.scrollRangeToVisible(range)
            isRestoringScrollPosition = false
        }

        func visibleTopLine(in textView: NSTextView, scrollView: NSScrollView) -> Int {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return 1
            }

            var point = scrollView.contentView.bounds.origin
            point.x += textView.textContainerInset.width + 4
            point.y += textView.textContainerInset.height + 4
            let containerPoint = textView.convert(point, from: scrollView.contentView)
            let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            return MarkdownScrollSync.lineNumber(forCharacterIndex: charIndex, in: textView.string)
        }

        func restoreScrollPosition(_ point: CGPoint, in scrollView: NSScrollView, shouldPublish: Bool = true) {
            isRestoringScrollPosition = true
            scrollView.contentView.scroll(to: point)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isRestoringScrollPosition = false

            if shouldPublish {
                publish(DocumentScrollPosition(point))
            }
        }

        func publishCurrentScrollPosition() {
            guard let scrollView else { return }
            publish(DocumentScrollPosition(scrollView.contentView.bounds.origin))
        }

        @objc private func scrollViewBoundsDidChange(_ notification: Notification) {
            guard !isRestoringScrollPosition else { return }
            publishCurrentScrollPosition()
        }

        @objc private func windowDidResignKey(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  window === textView?.window
            else { return }
            cancelFlowForFocusLoss()
        }

        @objc private func applicationDidResignActive(_ notification: Notification) {
            cancelFlowForFocusLoss()
        }

        func cancelFlowForFocusLoss() {
            pendingWritingToolsRequest = nil
            pendingInlinePredictionEdit = nil
            inlinePredictionContinuation = nil
            cancelFlowSuggestion()
            refreshNativeFlowAvailability()
        }

        private func publishVisibleTopLineIfNeeded(in textView: NSTextView, scrollView: NSScrollView) {
            guard !isRestoringScrollPosition else { return }
            let line = visibleTopLine(in: textView, scrollView: scrollView)
            guard line > 0, line != lastPublishedTopLine else { return }
            lastPublishedTopLine = line
            onVisibleTopLineChange?(line)
        }

        private func publish(_ position: DocumentScrollPosition) {
            guard !isWritingToolsActive,
                  documentID != nil,
                  position.isMeaningfullyDifferent(from: lastPublishedScrollPosition)
            else {
                if let textView, let scrollView {
                    publishVisibleTopLineIfNeeded(in: textView, scrollView: scrollView)
                }
                return
            }

            lastPublishedScrollPosition = position
            onScrollPositionChange(position)

            if let textView, let scrollView {
                publishVisibleTopLineIfNeeded(in: textView, scrollView: scrollView)
            }
        }

        func textView(
            _ nativeTextView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let textView = nativeTextView as? MarkdownNSTextView else { return true }
            guard let replacementString else { return true }
            if isWritingToolsActive {
                return prepareWritingToolsRangeUpdate(
                    replacing: affectedCharRange,
                    with: replacementString,
                    in: textView
                )
            }
            pendingInlinePredictionEdit = nil
            let source = textView.string as NSString
            guard let mode = flowSourceMode,
                  affectedCharRange.location != NSNotFound,
                  affectedCharRange.length == 0,
                  NSMaxRange(affectedCharRange) <= source.length,
                  Self.isOrdinaryProseInsertion(
                      replacementString,
                      in: source,
                      at: affectedCharRange.location,
                      mode: mode
                  ),
                  textView.selectedRange() == affectedCharRange,
                  !textView.hasMarkedText(),
                  textView.inlinePredictionType != .no,
                  hasTrustedInlinePredictionEligibility(in: textView)
            else {
                inlinePredictionContinuation = nil
                textView.applyInlinePredictionEligibility(false)
                return true
            }

            let replacementLength = (replacementString as NSString).length
            let resultingSelection = NSRange(
                location: affectedCharRange.location + replacementLength,
                length: 0
            )
            guard Self.insertionRemainsOutsideProtectedSyntax(
                in: source,
                insertionLocation: affectedCharRange.location,
                replacement: replacementString,
                mode: mode
            ) else {
                inlinePredictionContinuation = nil
                textView.applyInlinePredictionEligibility(false)
                return true
            }
            let contextLength = 32
            let precedingContextRange = NSRange(
                location: max(0, affectedCharRange.location - contextLength),
                length: min(contextLength, affectedCharRange.location)
            )
            let followingContextRange = NSRange(
                location: affectedCharRange.location,
                length: min(contextLength, source.length - affectedCharRange.location)
            )
            pendingInlinePredictionEdit = InlinePredictionEditCandidate(
                sourceRevision: revision,
                sourceUTF16Length: source.length,
                insertedRange: NSRange(
                    location: affectedCharRange.location,
                    length: replacementLength
                ),
                insertedText: replacementString,
                precedingContext: source.substring(with: precedingContextRange),
                followingContext: source.substring(with: followingContextRange),
                resultingSelection: resultingSelection
            )
            return true
        }

        private func prepareWritingToolsRangeUpdate(
            replacing affectedRange: NSRange,
            with replacement: String,
            in textView: NSTextView
        ) -> Bool {
            let sourceLength = (textView.string as NSString).length
            guard affectedRange.location != NSNotFound,
                  affectedRange.location >= 0,
                  affectedRange.length >= 0,
                  NSMaxRange(affectedRange) <= sourceLength
            else {
                pendingWritingToolsRangeUpdate = nil
                writingToolsProtectedRanges = nil
                return false
            }

            let replacementLength = (replacement as NSString).length
            let expectedLength = sourceLength - affectedRange.length + replacementLength
            guard let protectedRanges = writingToolsProtectedRanges else {
                pendingWritingToolsRangeUpdate = nil
                return false
            }

            let affectedUpperBound = NSMaxRange(affectedRange)
            let delta = replacementLength - affectedRange.length
            var rebasedRanges: [NSRange] = []
            rebasedRanges.reserveCapacity(protectedRanges.count)
            for protectedRange in protectedRanges {
                let protectedUpperBound = NSMaxRange(protectedRange)
                if affectedRange.length == 0 {
                    if affectedRange.location <= protectedRange.location {
                        rebasedRanges.append(NSRange(
                            location: protectedRange.location + delta,
                            length: protectedRange.length
                        ))
                    } else if affectedRange.location < protectedUpperBound {
                        pendingWritingToolsRangeUpdate = nil
                        return false
                    } else {
                        rebasedRanges.append(protectedRange)
                    }
                } else if affectedUpperBound <= protectedRange.location {
                    rebasedRanges.append(NSRange(
                        location: protectedRange.location + delta,
                        length: protectedRange.length
                    ))
                } else if affectedRange.location >= protectedUpperBound {
                    rebasedRanges.append(protectedRange)
                } else {
                    pendingWritingToolsRangeUpdate = nil
                    return false
                }
            }
            pendingWritingToolsRangeUpdate = PendingWritingToolsRangeUpdate(
                expectedUTF16Length: expectedLength,
                ranges: rebasedRanges
            )
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownNSTextView else { return }
            cancelFlowSuggestion()
            pendingWritingToolsRequest = nil
            revision += 1
            if isWritingToolsActive {
                let currentLength = (textView.string as NSString).length
                if let pendingWritingToolsRangeUpdate,
                   pendingWritingToolsRangeUpdate.expectedUTF16Length == currentLength {
                    writingToolsProtectedRanges = pendingWritingToolsRangeUpdate.ranges
                } else {
                    // An edit bypassed the delegate seam or did not match its announced
                    // replacement. Ignore the full enclosing range for the rest of the
                    // session instead of returning stale Markdown offsets.
                    writingToolsProtectedRanges = nil
                }
                pendingWritingToolsRangeUpdate = nil
            }
            if let candidate = pendingInlinePredictionEdit,
               candidate.sourceRevision == revision - 1,
               inlinePredictionEditCandidateMatchesCurrentState(candidate, in: textView),
               !textView.hasMarkedText(),
               !isWritingToolsActive {
                inlinePredictionContinuation = InlinePredictionContinuation(
                    revision: revision,
                    utf16Length: (textView.string as NSString).length,
                    selection: textView.selectedRange()
                )
            } else {
                inlinePredictionContinuation = nil
            }
            pendingInlinePredictionEdit = nil
            refreshSuppressedFlowSuggestion()
            if !isWritingToolsActive {
                scheduleProtectedRangesRefresh()
            }
            refreshNativeFlowAvailability()
            guard !isWritingToolsActive else { return }
            text = textView.string
            publishSelection()
            scheduleFlowCheck()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownNSTextView else { return }
            cancelFlowSuggestion()
            pendingWritingToolsRequest = nil
            if pendingInlinePredictionEdit.map({
                !inlinePredictionEditCandidateMatchesCurrentState($0, in: textView)
            }) == true {
                pendingInlinePredictionEdit = nil
            }
            if !inlinePredictionContinuationMatchesCurrentState(in: textView) {
                inlinePredictionContinuation = nil
            }
            refreshSuppressedFlowSuggestion()
            refreshNativeFlowAvailability()
            guard !isWritingToolsActive else { return }
            publishSelection()
            scheduleFlowCheck()
        }

        func publishSelection() {
            guard !isWritingToolsActive,
                  let textView,
                  let documentID,
                  let onSelectionChange
            else { return }
            let selectedRange = Self.boundedRange(textView.selectedRange(), in: textView.string)
            let selectedMarkdown = (textView.string as NSString).substring(with: selectedRange)
            let snapshot = MarkdownEditorSelectionSnapshot(
                documentID: documentID,
                revision: revision,
                selectedRange: selectedRange,
                selectedMarkdown: selectedMarkdown
            )
            guard snapshot != lastPublishedSelection else { return }
            lastPublishedSelection = snapshot
            onSelectionChange(snapshot)
        }

        func cancelFlowSuggestion() {
            let hadSuggestion = textView?.flowSuggestion != nil
            flowRequestToken &+= 1
            flowCheckTask?.cancel()
            flowCheckTask = nil
            pendingFlowProtectedRangesRetry = nil
            textView?.flowSuggestion = nil
            if hadSuggestion {
                refreshNativeFlowAvailability()
            }
        }

        func dismissFlowSuggestion() {
            if let suggestion = textView?.flowSuggestion {
                suppressedFlowSuggestion = SuppressedFlowSuggestion(
                    suggestion,
                    accepted: false
                )
            }
            cancelFlowSuggestion()
        }

        private func refreshSuppressedFlowSuggestion() {
            guard let suppression = suppressedFlowSuggestion else { return }
            guard suppression.documentID == documentID,
                  let textView,
                  suppression.targetStillExists(in: textView.string)
            else {
                suppressedFlowSuggestion = nil
                return
            }
        }

        private var currentProtectedRanges: [NSRange]? {
            guard let mode = flowSourceMode,
                  let textView,
                  let snapshot = protectedRangesSnapshot,
                  snapshot.revision == revision,
                  snapshot.text == textView.string,
                  snapshot.mode == mode
            else { return nil }
            return snapshot.ranges
        }

        func refreshNativeFlowAvailability() {
            guard let textView else { return }
            let ranges = currentProtectedRanges
            let authoritativeEligibility = ranges.map {
                caretIsOutsideProtectedRanges($0, in: textView)
            } == true
            let continuedEligibility = ranges == nil
                && (
                    inlinePredictionContinuationMatchesCurrentState(in: textView)
                        || pendingInlinePredictionEditMatchesCurrentState(in: textView)
                )
            let inlinePredictionsAllowed = !isWritingToolsActive
                && pendingWritingToolsRequest == nil
                && textView.flowSuggestion == nil
                && !textView.hasMarkedText()
                && (authoritativeEligibility || continuedEligibility)
            textView.applyInlinePredictionEligibility(inlinePredictionsAllowed)
            textView.applyWritingTools(
                flowSourceMode,
                protectedRangesReady: isWritingToolsActive || ranges != nil,
                invocationEligible: isWritingToolsActive || ranges.map {
                    selectionContainsEditableText(outside: $0, in: textView)
                } == true
            )
        }

        private func selectionContainsEditableText(
            outside protectedRanges: [NSRange],
            in textView: NSTextView
        ) -> Bool {
            let selection = textView.selectedRange()
            if selection.length == 0 {
                return caretIsOutsideProtectedRanges(protectedRanges, in: textView)
            }
            let protectedLength = protectedRanges.reduce(0) { length, range in
                length + NSIntersectionRange(range, selection).length
            }
            return protectedLength < selection.length
        }

        func nativeTextCheckingAllows(_ range: NSRange) -> Bool {
            guard flowSourceMode != nil,
                  range.location != NSNotFound,
                  range.length > 0,
                  let protectedRanges = currentProtectedRanges
            else { return false }
            return !protectedRanges.contains {
                NSIntersectionRange($0, range).length > 0
            }
        }

        private func caretIsOutsideProtectedRanges(
            _ ranges: [NSRange],
            in textView: NSTextView
        ) -> Bool {
            let selectedRange = textView.selectedRange()
            guard selectedRange.length == 0 else { return false }
            let sourceLength = (textView.string as NSString).length
            guard sourceLength > 0 else { return true }

            let caret = min(max(0, selectedRange.location), sourceLength)
            let probe = caret < sourceLength
                ? NSRange(location: caret, length: 1)
                : NSRange(location: sourceLength - 1, length: 1)
            return !ranges.contains {
                NSIntersectionRange($0, probe).length > 0
            }
        }

        private func hasTrustedInlinePredictionEligibility(in textView: NSTextView) -> Bool {
            if let ranges = currentProtectedRanges {
                return caretIsOutsideProtectedRanges(ranges, in: textView)
            }
            return inlinePredictionContinuationMatchesCurrentState(in: textView)
        }

        private func inlinePredictionContinuationMatchesCurrentState(
            in textView: NSTextView
        ) -> Bool {
            guard let continuation = inlinePredictionContinuation else { return false }
            return continuation.revision == revision
                && continuation.utf16Length == (textView.string as NSString).length
                && continuation.selection == textView.selectedRange()
                && continuation.selection.length == 0
                && !textView.hasMarkedText()
        }

        private func pendingInlinePredictionEditMatchesCurrentState(
            in textView: NSTextView
        ) -> Bool {
            guard let candidate = pendingInlinePredictionEdit else { return false }
            return candidate.sourceRevision == revision
                && inlinePredictionEditCandidateMatchesCurrentState(candidate, in: textView)
                && !textView.hasMarkedText()
        }

        private func inlinePredictionEditCandidateMatchesCurrentState(
            _ candidate: InlinePredictionEditCandidate,
            in textView: NSTextView
        ) -> Bool {
            let current = textView.string as NSString
            let precedingLength = (candidate.precedingContext as NSString).length
            let followingLength = (candidate.followingContext as NSString).length
            guard candidate.resultingSelection == textView.selectedRange(),
                  candidate.resultingSelection.length == 0,
                  current.length == candidate.sourceUTF16Length + candidate.insertedRange.length,
                  candidate.insertedRange.location >= precedingLength,
                  NSMaxRange(candidate.insertedRange) + followingLength <= current.length,
                  current.substring(with: candidate.insertedRange) == candidate.insertedText
            else { return false }
            let precedingRange = NSRange(
                location: candidate.insertedRange.location - precedingLength,
                length: precedingLength
            )
            let followingRange = NSRange(
                location: NSMaxRange(candidate.insertedRange),
                length: followingLength
            )
            return current.substring(with: precedingRange) == candidate.precedingContext
                && current.substring(with: followingRange) == candidate.followingContext
        }

        private static func isOrdinaryProseInsertion(
            _ replacement: String,
            in source: NSString,
            at insertionLocation: Int,
            mode: FlowSourceMode
        ) -> Bool {
            guard replacement.count == 1 else { return false }
            if replacement == " " {
                guard mode == .markdown else { return true }
                let precedingRange = NSRange(location: 0, length: insertionLocation)
                let newlineRange = source.range(
                    of: "\n",
                    options: .backwards,
                    range: precedingRange
                )
                let lineStart = newlineRange.location == NSNotFound ? 0 : NSMaxRange(newlineRange)
                let linePrefix = source.substring(with: NSRange(
                    location: lineStart,
                    length: insertionLocation - lineStart
                ))
                return linePrefix.unicodeScalars.contains {
                    !CharacterSet.whitespacesAndNewlines.contains($0)
                }
            }
            let scalars = replacement.unicodeScalars
            let isProseScalar: (Unicode.Scalar) -> Bool = {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }
            return scalars.contains(where: isProseScalar)
                && scalars.allSatisfy {
                    isProseScalar($0) || CharacterSet.nonBaseCharacters.contains($0)
                }
        }

        private static func insertionRemainsOutsideProtectedSyntax(
            in source: NSString,
            insertionLocation: Int,
            replacement: String,
            mode: FlowSourceMode
        ) -> Bool {
            let maximumExcerptLength = 2_048
            let replacementLength = (replacement as NSString).length
            let maximumSourceLength = maximumExcerptLength - replacementLength
            let tentativeStart = max(0, insertionLocation - maximumSourceLength / 2)
            let precedingNewline = source.range(
                of: "\n",
                options: .backwards,
                range: NSRange(
                    location: tentativeStart,
                    length: insertionLocation - tentativeStart
                )
            )
            let excerptStart = precedingNewline.location == NSNotFound
                ? tentativeStart
                : NSMaxRange(precedingNewline)
            let maximumEnd = min(source.length, excerptStart + maximumSourceLength)
            let followingNewline = source.range(
                of: "\n",
                range: NSRange(
                    location: insertionLocation,
                    length: maximumEnd - insertionLocation
                )
            )
            let excerptEnd = followingNewline.location == NSNotFound
                ? maximumEnd
                : NSMaxRange(followingNewline)
            let excerptRange = NSRange(
                location: excerptStart,
                length: excerptEnd - excerptStart
            )
            guard insertionLocation >= excerptStart,
                  insertionLocation <= excerptEnd
            else { return false }
            let sourceExcerpt = source.substring(with: excerptRange) as NSString
            let localInsertedRange = NSRange(
                location: insertionLocation - excerptStart,
                length: replacementLength
            )
            let excerpt = sourceExcerpt.replacingCharacters(
                in: NSRange(location: localInsertedRange.location, length: 0),
                with: replacement
            )
            let excerptLength = (excerpt as NSString).length
            let localCaret = NSMaxRange(localInsertedRange)
            let caretProbe: NSRange?
            if localCaret < excerptLength {
                caretProbe = NSRange(location: localCaret, length: 1)
            } else if localCaret > 0 {
                caretProbe = NSRange(location: localCaret - 1, length: 1)
            } else {
                caretProbe = nil
            }
            let ranges = FlowProtectedRangeService().protectedRanges(
                in: excerpt,
                mode: mode
            )
            return !ranges.contains { protectedRange in
                NSIntersectionRange(protectedRange, localInsertedRange).length > 0
                    || caretProbe.map {
                        NSIntersectionRange(protectedRange, $0).length > 0
                    } == true
            }
        }

        private func scheduleFlowCheck(completedSentenceEndingAt endOffset: Int? = nil) {
            guard !isWritingToolsActive,
                  let mode = flowSourceMode,
                  flowCheckingOptions.checksSpelling || flowCheckingOptions.checksGrammar,
                  let textView,
                  flowFocusValidator(textView),
                  !textView.hasMarkedText(),
                  let documentID,
                  let plan = EditorFlowCheckPlanner.plan(
                    in: textView.string,
                    selectedRange: endOffset.map {
                        NSRange(location: $0, length: 0)
                    } ?? textView.selectedRange()
                  )
            else { return }

            let caret = textView.selectedRange().location + textView.selectedRange().length
            let token = flowRequestToken
            let checkedText = (textView.string as NSString).substring(with: plan.range)
            let snapshot = EditorFlowCheckSnapshot(
                documentID: documentID,
                revision: revision,
                checkedText: checkedText,
                checkedRange: plan.range,
                selectedRange: textView.selectedRange(),
                caretUTF16Offset: caret,
                options: flowCheckingOptions,
                sourceMode: mode,
                offersSentenceBatch: endOffset != nil || plan.offersSentenceBatch,
                checksCompletedStructuralSentence: endOffset != nil
            )
            flowCheckTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: plan.delayNanoseconds)
                } catch {
                    return
                }
                guard let self, self.isCurrentFlowSnapshot(snapshot, token: token) else { return }
                self.requestFlowCorrection(for: snapshot, token: token)
            }
        }

        func scheduleCompletedSentenceFlowCheck(endingAt endOffset: Int) {
            guard let textView,
                  endOffset > 0,
                  endOffset <= (textView.string as NSString).length
            else { return }
            flowRequestToken &+= 1
            flowCheckTask?.cancel()
            flowCheckTask = nil
            pendingFlowProtectedRangesRetry = nil
            scheduleFlowCheck(completedSentenceEndingAt: endOffset)
        }

        private func requestFlowCorrection(
            for snapshot: EditorFlowCheckSnapshot,
            token: Int
        ) {
            guard isCurrentFlowSnapshot(snapshot, token: token), let textView else { return }

            let documentTag = textView.spellCheckerDocumentTag
            flowCheckingClient.request(
                snapshot.checkedText,
                NSRange(location: 0, length: (snapshot.checkedText as NSString).length),
                EditorFlowCheckingTypes.value(for: snapshot.options),
                documentTag
            ) { [weak self] results, orthography in
                DispatchQueue.main.async { [weak self] in
                    self?.receiveFlowResults(
                        results,
                        orthography: orthography,
                        snapshot: snapshot,
                        token: token,
                        documentTag: documentTag
                    )
                }
            }
        }

        private func receiveFlowResults(
            _ results: [NSTextCheckingResult],
            orthography: NSOrthography?,
            snapshot: EditorFlowCheckSnapshot,
            token: Int,
            documentTag: Int
        ) {
            guard isCurrentFlowSnapshot(snapshot, token: token) else { return }
            let checker = NSSpellChecker.shared
            let localCandidates = EditorFlowCorrectionResolver.concreteCorrections(
                in: snapshot.checkedText,
                caretUTF16Offset: (snapshot.checkedText as NSString).length,
                results: results,
                orthography: orthography,
                spellingCorrection: { range, orthography in
                    guard let language = checker.language(
                        forWordRange: range,
                        in: snapshot.checkedText,
                        orthography: orthography
                    ) ?? orthography?.dominantLanguage else { return nil }
                    return checker.correction(
                        forWordRange: range,
                        in: snapshot.checkedText,
                        language: language,
                        inSpellDocumentWithTag: documentTag
                    )
                }
            )
            let ambiguousGrammarCandidates = EditorFlowCorrectionResolver
                .ambiguousGrammarCorrections(
                    in: snapshot.checkedText,
                    caretUTF16Offset: (snapshot.checkedText as NSString).length,
                    results: results
                )
            guard !localCandidates.isEmpty || !ambiguousGrammarCandidates.isEmpty,
                  let textView
            else { return }
            guard let ranges = protectedRanges(for: snapshot, in: textView) else {
                pendingFlowProtectedRangesRetry = PendingFlowProtectedRangesRetry(
                    snapshot: snapshot,
                    token: token
                )
                return
            }
            pendingFlowProtectedRangesRetry = nil
            if let ambiguousCandidate = grammarCandidateForValidation(
                ambiguousGrammarCandidates,
                concreteCandidates: localCandidates,
                snapshot: snapshot,
                protectedRanges: ranges,
                in: textView
            ) {
                validateGrammarAlternatives(
                    ambiguousCandidate,
                    nextIndex: 0,
                    cleanReplacements: [],
                    concreteCandidates: localCandidates,
                    snapshot: snapshot,
                    token: token,
                    documentTag: documentTag
                )
                return
            }
            presentFlowCandidates(
                localCandidates,
                snapshot: snapshot,
                token: token
            )
        }

        private func presentFlowCandidates(
            _ localCandidates: [EditorFlowCorrectionCandidate],
            snapshot: EditorFlowCheckSnapshot,
            token: Int
        ) {
            guard !localCandidates.isEmpty,
                  isCurrentFlowSnapshot(snapshot, token: token),
                  let textView,
                  let ranges = protectedRanges(for: snapshot, in: textView)
            else { return }
            let sourceLength = (textView.string as NSString).length
            let caretProbe: NSRange?
            if snapshot.caretUTF16Offset < sourceLength {
                caretProbe = NSRange(location: snapshot.caretUTF16Offset, length: 1)
            } else if snapshot.caretUTF16Offset > 0 {
                caretProbe = NSRange(location: snapshot.caretUTF16Offset - 1, length: 1)
            } else {
                caretProbe = nil
            }
            if !snapshot.checksCompletedStructuralSentence {
                guard caretProbe.map({ probe in
                    !ranges.contains { NSIntersectionRange($0, probe).length > 0 }
                }) != false else { return }
            }

            let checkedSource = snapshot.checkedText as NSString
            let eligibleCandidates = localCandidates.compactMap { candidate -> EditorFlowCorrectionEdit? in
                guard (candidate.kind == .spelling && snapshot.options.checksSpelling) ||
                        (candidate.kind == .grammar && snapshot.options.checksGrammar)
                else { return nil }
                let absoluteRange = NSRange(
                    location: snapshot.checkedRange.location + candidate.range.location,
                    length: candidate.range.length
                )
                guard NSMaxRange(absoluteRange) <= sourceLength,
                      !ranges.contains(where: {
                        NSIntersectionRange($0, absoluteRange).length > 0
                      })
                else { return nil }
                let originalText = checkedSource.substring(with: candidate.range)
                guard Self.isCompactFlowEdit(
                    originalText: originalText,
                    replacementText: candidate.replacementText
                ) else { return nil }
                return EditorFlowCorrectionEdit(
                    range: absoluteRange,
                    originalText: originalText,
                    replacementText: candidate.replacementText,
                    kind: candidate.kind
                )
            }
            var eligibleEdits: [EditorFlowCorrectionEdit] = []
            for edit in eligibleCandidates {
                if let duplicateIndex = eligibleEdits.firstIndex(where: {
                    $0.range == edit.range && $0.replacementText == edit.replacementText
                }) {
                    if eligibleEdits[duplicateIndex].kind == .grammar, edit.kind == .spelling {
                        eligibleEdits[duplicateIndex] = edit
                    }
                } else {
                    eligibleEdits.append(edit)
                }
            }
            let conflictFreeEdits = eligibleEdits.enumerated().compactMap { index, edit in
                let overlapsAnother = eligibleEdits.enumerated().contains { otherIndex, other in
                    guard index != otherIndex else { return false }
                    return NSIntersectionRange(edit.range, other.range).length > 0
                }
                return overlapsAnother ? nil : edit
            }
            let unsuppressedEdits = conflictFreeEdits.filter {
                suppressedFlowSuggestion?.suppresses($0) != true
            }
            guard !unsuppressedEdits.isEmpty else { return }
            let selectedEdits: [EditorFlowCorrectionEdit]
            if snapshot.offersSentenceBatch {
                // The compact cue shows two concrete replacements. Never apply a
                // third unseen edit; another pass can offer any remaining issue.
                selectedEdits = Array(unsuppressedEdits.prefix(2))
            } else if let nearest = unsuppressedEdits
                .filter({ edit in
                    Self.isRecentFlowCorrection(
                        edit,
                        caretUTF16Offset: snapshot.caretUTF16Offset,
                        in: textView.string
                    )
                })
                .min(by: { left, right in
                    let leftDistance = snapshot.caretUTF16Offset - NSMaxRange(left.range)
                    let rightDistance = snapshot.caretUTF16Offset - NSMaxRange(right.range)
                    if leftDistance == rightDistance {
                        return left.range.location > right.range.location
                    }
                    return leftDistance < rightDistance
                }) {
                selectedEdits = [nearest]
            } else {
                return
            }
            guard isCurrentFlowSnapshot(snapshot, token: token)
            else { return }
            textView.flowSuggestion = EditorFlowSuggestion(
                documentID: snapshot.documentID,
                revision: snapshot.revision,
                selectedRange: snapshot.selectedRange,
                caretUTF16Offset: snapshot.caretUTF16Offset,
                edits: selectedEdits
            )
            refreshNativeFlowAvailability()
        }

        private func protectedRanges(
            for snapshot: EditorFlowCheckSnapshot,
            in textView: NSTextView
        ) -> [NSRange]? {
            protectedRangesSnapshot.flatMap { protectedSnapshot -> [NSRange]? in
                guard protectedSnapshot.revision == snapshot.revision,
                      protectedSnapshot.text == textView.string,
                      protectedSnapshot.mode == snapshot.sourceMode
                else { return nil }
                return protectedSnapshot.ranges
            }
        }

        private func grammarCandidateForValidation(
            _ candidates: [EditorFlowAmbiguousGrammarCandidate],
            concreteCandidates: [EditorFlowCorrectionCandidate],
            snapshot: EditorFlowCheckSnapshot,
            protectedRanges: [NSRange],
            in textView: NSTextView
        ) -> EditorFlowAmbiguousGrammarCandidate? {
            guard snapshot.offersSentenceBatch,
                  snapshot.options.checksGrammar,
                  candidates.count == 1,
                  let candidate = candidates.first,
                  candidate.replacementTexts.count > 1,
                  candidate.replacementTexts.count <= EditorFlowCorrectionResolver
                    .maximumValidatedGrammarAlternatives
            else { return nil }

            let checkedSource = snapshot.checkedText as NSString
            guard candidate.range.location >= 0,
                  candidate.range.length > 0,
                  NSMaxRange(candidate.range) <= checkedSource.length,
                  concreteCandidates.allSatisfy({
                    NSIntersectionRange($0.range, candidate.range).length == 0
                  })
            else { return nil }
            let absoluteRange = NSRange(
                location: snapshot.checkedRange.location + candidate.range.location,
                length: candidate.range.length
            )
            guard NSMaxRange(absoluteRange) <= (textView.string as NSString).length,
                  !protectedRanges.contains(where: {
                    NSIntersectionRange($0, absoluteRange).length > 0
                  })
            else { return nil }

            let originalText = checkedSource.substring(with: candidate.range)
            guard candidate.replacementTexts.allSatisfy({
                Self.isCompactFlowEdit(
                    originalText: originalText,
                    replacementText: $0
                )
            }) else { return nil }
            return candidate
        }

        private func validateGrammarAlternatives(
            _ candidate: EditorFlowAmbiguousGrammarCandidate,
            nextIndex: Int,
            cleanReplacements: [String],
            concreteCandidates: [EditorFlowCorrectionCandidate],
            snapshot: EditorFlowCheckSnapshot,
            token: Int,
            documentTag: Int
        ) {
            guard isCurrentFlowSnapshot(snapshot, token: token) else { return }
            if cleanReplacements.count > 1 || nextIndex >= candidate.replacementTexts.count {
                finishGrammarAlternativeValidation(
                    candidate,
                    cleanReplacements: cleanReplacements,
                    concreteCandidates: concreteCandidates,
                    snapshot: snapshot,
                    token: token
                )
                return
            }

            let replacement = candidate.replacementTexts[nextIndex]
            let validationText = (snapshot.checkedText as NSString).replacingCharacters(
                in: candidate.range,
                with: replacement
            )
            // On macOS the unified checker may omit grammar results when a
            // validation request asks for grammar alone. Request the complete
            // deterministic checking set, then ignore unrelated spelling
            // results outside the substituted grammar target.
            let validationTypes = NSTextCheckingResult.CheckingType.orthography.rawValue
                | NSTextCheckingResult.CheckingType.spelling.rawValue
                | NSTextCheckingResult.CheckingType.correction.rawValue
                | NSTextCheckingResult.CheckingType.grammar.rawValue
            let validationRange = NSRange(
                location: candidate.range.location,
                length: (replacement as NSString).length
            )
            flowCheckingClient.request(
                validationText,
                NSRange(location: 0, length: (validationText as NSString).length),
                validationTypes,
                documentTag
            ) { [weak self] results, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.isCurrentFlowSnapshot(snapshot, token: token)
                    else { return }
                    var nextCleanReplacements = cleanReplacements
                    if Self.grammarValidationIsClean(
                        results,
                        replacementRange: validationRange
                    ),
                       !nextCleanReplacements.contains(replacement) {
                        nextCleanReplacements.append(replacement)
                    }
                    self.validateGrammarAlternatives(
                        candidate,
                        nextIndex: nextIndex + 1,
                        cleanReplacements: nextCleanReplacements,
                        concreteCandidates: concreteCandidates,
                        snapshot: snapshot,
                        token: token,
                        documentTag: documentTag
                    )
                }
            }
        }

        private func finishGrammarAlternativeValidation(
            _ candidate: EditorFlowAmbiguousGrammarCandidate,
            cleanReplacements: [String],
            concreteCandidates: [EditorFlowCorrectionCandidate],
            snapshot: EditorFlowCheckSnapshot,
            token: Int
        ) {
            guard isCurrentFlowSnapshot(snapshot, token: token) else { return }

            var resolvedCandidates = concreteCandidates
            if cleanReplacements.count == 1, let replacement = cleanReplacements.first {
                resolvedCandidates.append(EditorFlowCorrectionCandidate(
                    range: candidate.range,
                    replacementText: replacement,
                    kind: .grammar
                ))
            }
            resolvedCandidates.sort { left, right in
                if left.range.location == right.range.location {
                    return left.range.length < right.range.length
                }
                return left.range.location < right.range.location
            }
            presentFlowCandidates(
                resolvedCandidates,
                snapshot: snapshot,
                token: token
            )
        }

        private static func grammarValidationIsClean(
            _ results: [NSTextCheckingResult],
            replacementRange: NSRange
        ) -> Bool {
            !results.contains { result in
                switch result.resultType {
                case .grammar:
                    return true
                case .spelling, .correction:
                    return result.range.location == NSNotFound
                        || NSIntersectionRange(result.range, replacementRange).length > 0
                default:
                    return false
                }
            }
        }

        private static func isRecentFlowCorrection(
            _ edit: EditorFlowCorrectionEdit,
            caretUTF16Offset: Int,
            in text: String
        ) -> Bool {
            let source = text as NSString
            let editEnd = NSMaxRange(edit.range)
            guard editEnd <= caretUTF16Offset, caretUTF16Offset <= source.length else {
                return false
            }
            let trailing = source.substring(with: NSRange(
                location: editEnd,
                length: caretUTF16Offset - editEnd
            ))
            return trailing.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.punctuationCharacters.contains($0)
            }
        }

        private static func isCompactFlowEdit(
            originalText: String,
            replacementText: String
        ) -> Bool {
            let maximumVisibleCharacters = 24
            return !originalText.containsNewline
                && !replacementText.containsNewline
                && originalText.count <= maximumVisibleCharacters
                && replacementText.count <= maximumVisibleCharacters
        }

        func isCurrentFlowSnapshot(_ snapshot: EditorFlowCheckSnapshot, token: Int) -> Bool {
            guard token == flowRequestToken,
                  !isWritingToolsActive,
                  flowSourceMode == snapshot.sourceMode,
                  flowCheckingOptions == snapshot.options,
                  documentID == snapshot.documentID,
                  revision == snapshot.revision,
                  let textView,
                  textView.selectedRange() == snapshot.selectedRange,
                  snapshot.caretUTF16Offset == snapshot.selectedRange.location + snapshot.selectedRange.length,
                  snapshot.checkedRange.location >= 0,
                  NSMaxRange(snapshot.checkedRange) <= (textView.string as NSString).length,
                  (textView.string as NSString).substring(with: snapshot.checkedRange) == snapshot.checkedText,
                  flowFocusValidator(textView),
                  !textView.hasMarkedText()
            else { return false }
            return true
        }

        @discardableResult
        func acceptFlowSuggestion(_ suggestion: EditorFlowSuggestion) -> Bool {
            guard let textView,
                  let textStorage = textView.textStorage,
                  textView.flowSuggestion == suggestion,
                  suggestion.matches(
                    documentID: documentID,
                    revision: revision,
                    text: textView.string,
                    selectedRange: textView.selectedRange()
                  ),
                  let firstEdit = suggestion.edits.first,
                  let lastEdit = suggestion.edits.last
            else {
                cancelFlowSuggestion()
                return false
            }

            let replacementRange = NSRange(
                location: firstEdit.range.location,
                length: NSMaxRange(lastEdit.range) - firstEdit.range.location
            )
            let replacement = NSMutableAttributedString(
                attributedString: textStorage.attributedSubstring(from: replacementRange)
            )
            for edit in suggestion.edits.reversed() {
                replacement.replaceCharacters(
                    in: NSRange(
                        location: edit.range.location - replacementRange.location,
                        length: edit.range.length
                    ),
                    with: edit.replacementText
                )
            }
            let replacementText = replacement.string
            guard textView.shouldChangeText(
                in: replacementRange,
                replacementString: replacementText
            ) else {
                cancelFlowSuggestion()
                return false
            }

            let caretDelta = suggestion.edits.reduce(0) { delta, edit in
                guard edit.range.location < suggestion.caretUTF16Offset else { return delta }
                return delta + (edit.replacementText as NSString).length - edit.range.length
            }
            suppressedFlowSuggestion = SuppressedFlowSuggestion(suggestion, accepted: true)
            cancelFlowSuggestion()
            textView.breakUndoCoalescing()
            textView.undoManager?.beginUndoGrouping()
            textStorage.replaceCharacters(in: replacementRange, with: replacement)
            textView.didChangeText()
            let nextRange = NSRange(
                location: max(0, suggestion.caretUTF16Offset + caretDelta),
                length: 0
            )
            textView.setSelectedRange(nextRange)
            textView.scrollRangeToVisible(nextRange)
            textView.undoManager?.endUndoGrouping()
            textView.undoManager?.setActionName(
                suggestion.edits.count == 1
                    ? "Accept Flow Correction"
                    : "Fix \(suggestion.edits.count) Flow Issues"
            )
            textView.breakUndoCoalescing()
            return true
        }

        @discardableResult
        func requestWritingTools() -> Bool {
            guard writingToolsAvailability(),
                  !isWritingToolsActive,
                  flowSourceMode != nil,
                  let documentID,
                  let textView,
                  flowFocusValidator(textView)
            else { return false }

            cancelFlowSuggestion()
            pendingInlinePredictionEdit = nil
            inlinePredictionContinuation = nil
            pendingWritingToolsRequest = PendingWritingToolsRequest(
                documentID: documentID,
                revision: revision,
                selectedRange: textView.selectedRange()
            )
            refreshNativeFlowAvailability()
            if currentProtectedRanges != nil {
                return presentPendingWritingToolsRequestIfReady()
            }
            scheduleProtectedRangesRefresh(delayNanoseconds: 0)
            return true
        }

        @discardableResult
        private func presentPendingWritingToolsRequestIfReady() -> Bool {
            guard let request = pendingWritingToolsRequest,
                  request.documentID == documentID,
                  request.revision == revision,
                  let textView,
                  request.selectedRange == textView.selectedRange(),
                  flowFocusValidator(textView),
                  let ranges = currentProtectedRanges,
                  selectionContainsEditableText(outside: ranges, in: textView)
            else {
                pendingWritingToolsRequest = nil
                refreshNativeFlowAvailability()
                return false
            }
            pendingWritingToolsRequest = nil
            guard writingToolsAvailability() else {
                refreshNativeFlowAvailability()
                return false
            }
            writingToolsPresenter(textView)
            return true
        }

        @available(macOS 15.0, *)
        func textViewWritingToolsWillBegin(_ textView: NSTextView) {
            guard flowSourceMode != nil,
                  !isWritingToolsActive,
                  let documentID
            else { return }
            pendingWritingToolsRequest = nil
            cancelFlowSuggestion()
            guard let protectedRanges = currentProtectedRanges else {
                rejectWritingToolsStart(in: textView)
                return
            }
            guard onWritingToolsStateChange?(documentID, true) ?? true else {
                rejectWritingToolsStart(in: textView)
                return
            }
            writingToolsDocumentID = documentID
            writingToolsProtectedRanges = protectedRanges
            pendingWritingToolsRangeUpdate = nil
            refreshNativeFlowAvailability()
        }

        @available(macOS 15.0, *)
        private func rejectWritingToolsStart(in textView: NSTextView) {
            if #available(macOS 15.2, *) {
                textView.writingToolsCoordinator?.stopWritingTools()
            } else {
                textView.writingToolsBehavior = .none
            }
        }

        @available(macOS 15.0, *)
        func textViewWritingToolsDidEnd(_ textView: NSTextView) {
            finishWritingToolsSessionIfNeeded()
        }

        @available(macOS 15.0, *)
        func textView(
            _ textView: NSTextView,
            writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange
        ) -> [NSValue] {
            guard flowSourceMode != nil else { return [] }
            let ranges = currentProtectedRanges ?? (isWritingToolsActive ? writingToolsProtectedRanges : nil)
            guard let ranges else {
                guard enclosingRange.location != NSNotFound, enclosingRange.length > 0 else { return [] }
                return [NSValue(range: NSRange(location: 0, length: enclosingRange.length))]
            }
            return ranges.compactMap { absoluteRange in
                let intersection = NSIntersectionRange(absoluteRange, enclosingRange)
                guard intersection.length > 0 else { return nil }
                return NSValue(range: NSRange(
                    location: intersection.location - enclosingRange.location,
                    length: intersection.length
                ))
            }
        }

        func textView(
            _ textView: NSTextView,
            shouldSetSpellingState value: Int,
            range affectedCharRange: NSRange
        ) -> Int {
            guard value != 0 else { return value }
            guard flowSourceMode != nil else { return 0 }
            guard affectedCharRange.location != NSNotFound,
                  affectedCharRange.length > 0,
                  let ranges = currentProtectedRanges
            else { return 0 }
            return ranges.contains {
                NSIntersectionRange($0, affectedCharRange).length > 0
            } ? 0 : value
        }

        func textView(
            _ textView: NSTextView,
            willCheckTextIn range: NSRange,
            options: [NSSpellChecker.OptionKey: Any],
            types checkingTypes: UnsafeMutablePointer<NSTextCheckingTypes>
        ) -> [NSSpellChecker.OptionKey: Any] {
            let excludedTypes = NSTextCheckingResult.CheckingType.spelling.rawValue
                | NSTextCheckingResult.CheckingType.grammar.rawValue
                | NSTextCheckingResult.CheckingType.correction.rawValue
            guard flowSourceMode != nil,
                  range.location != NSNotFound,
                  range.length > 0,
                  let ranges = currentProtectedRanges
            else {
                checkingTypes.pointee &= ~excludedTypes
                return options
            }
            if ranges.contains(where: {
                NSIntersectionRange($0, range).length == range.length
            }) {
                checkingTypes.pointee &= ~excludedTypes
            }
            return options
        }

        func textView(
            _ textView: NSTextView,
            didCheckTextIn checkedRange: NSRange,
            types checkingTypes: NSTextCheckingTypes,
            options: [NSSpellChecker.OptionKey: Any],
            results: [NSTextCheckingResult],
            orthography: NSOrthography,
            wordCount: Int
        ) -> [NSTextCheckingResult] {
            guard flowSourceMode != nil,
                  checkedRange.location != NSNotFound,
                  checkedRange.length > 0,
                  let protectedRanges = currentProtectedRanges
            else { return [] }
            return results.filter { result in
                switch result.resultType {
                case .spelling, .grammar, .correction:
                    break
                default:
                    return true
                }
                let resultRange = result.range
                guard resultRange.location != NSNotFound,
                      resultRange.location >= 0,
                      resultRange.length > 0,
                      NSMaxRange(resultRange) <= (textView.string as NSString).length
                else { return false }
                return !protectedRanges.contains {
                    NSIntersectionRange($0, resultRange).length > 0
                }
            }
        }

        private func scheduleProtectedRangesRefresh(
            delayNanoseconds: UInt64 = 140_000_000
        ) {
            protectedRangesGeneration &+= 1
            let generation = protectedRangesGeneration
            let previousTask = protectedRangesTask
            previousTask?.cancel()
            protectedRangesSnapshot = nil
            refreshNativeFlowAvailability()
            guard !isWritingToolsActive,
                  flowSourceMode != nil,
                  textView != nil
            else { return }

            let provider = protectedRangeProvider
            protectedRangesTask = Task { @MainActor [weak self] in
                await previousTask?.value
                guard !Task.isCancelled else { return }
                if delayNanoseconds > 0 {
                    do {
                        try await Task.sleep(nanoseconds: delayNanoseconds)
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled,
                      let self,
                      generation == self.protectedRangesGeneration,
                      !self.isWritingToolsActive,
                      let mode = self.flowSourceMode,
                      let textView = self.textView
                else { return }
                let text = textView.string
                let capturedRevision = self.revision
                let worker = Task.detached(priority: .utility) {
                    provider(text, mode)
                }
                let ranges = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled,
                      generation == self.protectedRangesGeneration,
                      capturedRevision == self.revision,
                      self.flowSourceMode == mode,
                      self.textView?.string == text
                else { return }
                self.protectedRangesSnapshot = ProtectedRangesSnapshot(
                    revision: capturedRevision,
                    text: text,
                    mode: mode,
                    ranges: ranges
                )
                self.inlinePredictionContinuation = nil
                self.protectedRangesTask = nil
                self.refreshNativeFlowAvailability()
                self.presentPendingWritingToolsRequestIfReady()
                if let retry = self.pendingFlowProtectedRangesRetry,
                   retry.snapshot.revision == capturedRevision,
                   self.isCurrentFlowSnapshot(retry.snapshot, token: retry.token) {
                    self.pendingFlowProtectedRangesRetry = nil
                    self.requestFlowCorrection(for: retry.snapshot, token: retry.token)
                }
            }
        }

        private func finishWritingToolsSessionIfNeeded() {
            guard isWritingToolsActive, let activeDocumentID = writingToolsDocumentID else { return }
            let finalText = textView?.string
            writingToolsDocumentID = nil
            writingToolsProtectedRanges = nil
            pendingWritingToolsRangeUpdate = nil
            pendingWritingToolsRequest = nil
            pendingInlinePredictionEdit = nil
            inlinePredictionContinuation = nil
            cancelFlowSuggestion()
            lastSyntaxText = nil
            lastPublishedSelection = nil
            scheduleProtectedRangesRefresh(delayNanoseconds: 0)

            if let finalText {
                if let onWritingToolsTextCommit {
                    onWritingToolsTextCommit(activeDocumentID, finalText)
                } else if documentID == activeDocumentID {
                    text = finalText
                }
            }
            publishSelection()
            _ = onWritingToolsStateChange?(activeDocumentID, false)
        }

        func open(_ link: MarkdownWorkspaceLink) -> Bool {
            guard let documentID, let onOpenLink else { return false }
            onOpenLink(MarkdownEditorLinkRequest(
                documentID: documentID,
                revision: revision,
                link: link
            ))
            return true
        }

        func requestImagePaste(_ image: NSImage) -> Bool {
            guard !isWritingToolsActive,
                  let textView,
                  let documentID,
                  let onImagePasteRequest
            else { return false }

            let capturedRevision = revision
            let capturedText = textView.string
            let capturedRange = Self.boundedRange(textView.selectedRange(), in: capturedText)
            let request = MarkdownImagePasteRequest(
                documentID: documentID,
                revision: capturedRevision,
                sourceText: capturedText,
                selectedRange: capturedRange,
                image: image
            ) { [weak self] markdown in
                self?.insertMarkdown(
                    markdown,
                    documentID: documentID,
                    expectedRevision: capturedRevision,
                    expectedText: capturedText,
                    expectedRange: capturedRange
                ) ?? false
            }
            onImagePasteRequest(request)
            return true
        }

        func requestFileDrop(_ urls: [URL], atUTF16Offset offset: Int) -> Bool {
            guard !isWritingToolsActive,
                  !urls.isEmpty,
                  let textView,
                  let documentID,
                  let onFileDropRequest
            else { return false }

            let capturedRevision = revision
            let capturedText = textView.string
            let boundedOffset = min(max(0, offset), (capturedText as NSString).length)
            let capturedRange = NSRange(location: boundedOffset, length: 0)
            let request = MarkdownFileDropRequest(
                documentID: documentID,
                revision: capturedRevision,
                sourceText: capturedText,
                insertionRange: capturedRange,
                urls: urls
            ) { [weak self] markdown in
                self?.insertMarkdown(
                    markdown,
                    documentID: documentID,
                    expectedRevision: capturedRevision,
                    expectedText: capturedText,
                    expectedRange: capturedRange,
                    requiresSelectionMatch: false
                ) ?? false
            }
            onFileDropRequest(request)
            return true
        }

        private func insertMarkdown(
            _ markdown: String,
            documentID: String,
            expectedRevision: Int,
            expectedText: String,
            expectedRange: NSRange,
            requiresSelectionMatch: Bool = true
        ) -> Bool {
            guard !isWritingToolsActive,
                  !markdown.isEmpty,
                  self.documentID == documentID,
                  revision == expectedRevision,
                  let textView,
                  let textStorage = textView.textStorage,
                  textView.string == expectedText,
                  (!requiresSelectionMatch || textView.selectedRange() == expectedRange),
                  NSMaxRange(expectedRange) <= (expectedText as NSString).length,
                  textView.shouldChangeText(in: expectedRange, replacementString: markdown)
            else { return false }

            textView.breakUndoCoalescing()
            textView.undoManager?.beginUndoGrouping()
            textStorage.replaceCharacters(in: expectedRange, with: markdown)
            textView.didChangeText()
            let caret = expectedRange.location + (markdown as NSString).length
            let nextRange = NSRange(location: caret, length: 0)
            textView.setSelectedRange(nextRange)
            textView.scrollRangeToVisible(nextRange)
            textView.undoManager?.endUndoGrouping()
            textView.breakUndoCoalescing()
            return true
        }

        func apply(_ request: MarkdownTextEditorCommandRequest) {
            guard request.serial != lastCommandSerial else { return }
            lastCommandSerial = request.serial
            _ = apply(request.command)
        }

        func apply(_ command: MarkdownTextEditorCommand) -> Bool {
            guard !isWritingToolsActive,
                  let textView,
                  let textStorage = textView.textStorage
            else { return false }
            let selectedRange = textView.selectedRange()
            let result = MarkdownTextCommandApplier.apply(
                command,
                to: textView.string,
                selectedRange: selectedRange
            )
            let currentReplacementText = (textView.string as NSString).substring(with: result.replacementRange)
            guard result.replacementText != currentReplacementText || result.selectedRange != selectedRange else {
                return false
            }

            guard textView.shouldChangeText(in: result.replacementRange, replacementString: result.replacementText) else {
                return false
            }

            textStorage.replaceCharacters(in: result.replacementRange, with: result.replacementText)
            textView.didChangeText()
            textView.setSelectedRange(result.selectedRange)
            textView.scrollRangeToVisible(result.selectedRange)
            textView.window?.makeFirstResponder(textView)
            text = textView.string
            return true
        }

        func navigate(to location: MarkdownSourceLocation, in textView: NSTextView) {
            guard !isWritingToolsActive,
                  lastNavigatedLocation != location || textView.window?.firstResponder !== textView
            else { return }

            let offset = characterOffset(for: location, in: textView.string)
            let range = NSRange(location: offset, length: 0)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
            lastNavigatedLocation = location

            DispatchQueue.main.async {
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
                textView.window?.makeFirstResponder(textView)
            }
        }

        private func characterOffset(for location: MarkdownSourceLocation, in text: String) -> Int {
            let nsText = text as NSString
            let targetLine = max(1, location.line)
            var currentLine = 1
            var lineStart = 0

            while currentLine < targetLine, lineStart < nsText.length {
                let lineRange = nsText.lineRange(for: NSRange(location: lineStart, length: 0))
                let nextLocation = NSMaxRange(lineRange)
                guard nextLocation > lineStart else { break }
                lineStart = nextLocation
                currentLine += 1
            }

            let lineRange = nsText.lineRange(for: NSRange(location: min(lineStart, nsText.length), length: 0))
            let lineEnd = min(NSMaxRange(lineRange), nsText.length)
            return min(lineStart + max(0, location.offset), lineEnd)
        }

        func applySearch(
            _ state: DocumentSearchState,
            options: MonknotSearchOptions = MonknotSearchOptions(),
            theme: AppTheme,
            in textView: NSTextView
        ) -> DocumentSearchResult {
            guard !isWritingToolsActive else {
                return DocumentSearchResult(
                    currentIndex: state.currentIndex,
                    totalCount: state.totalCount
                )
            }
            let request = DocumentSearchRequest(state, options: options)
            let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard state.isPresented, !query.isEmpty else {
                clearSearchHighlights(in: textView)
                lastSearchQuery = ""
                lastSearchOptions = options
                lastSearchedText = textView.string
                currentMatchIndex = 0
                lastNavigationSerial = request.navigationSerial
                return .init()
            }

            let text = textView.string
            let queryChanged = query != lastSearchQuery || options != lastSearchOptions
            let textChanged = text != lastSearchedText
            let navigationChanged = request.navigationSerial != lastNavigationSerial
            let highlightTheme = SearchHighlightTheme(theme: theme)

            if queryChanged || textChanged {
                searchMatches = matchRanges(for: query, options: options, in: text)
            }

            let matches = searchMatches
            guard !matches.isEmpty else {
                clearSearchHighlights(in: textView)
                lastSearchQuery = query
                lastSearchOptions = options
                lastSearchedText = text
                currentMatchIndex = 0
                lastNavigationSerial = request.navigationSerial
                return .init()
            }

            let previousMatchIndex = currentMatchIndex

            if queryChanged {
                currentMatchIndex = firstMatchIndex(atOrAfter: textView.selectedRange().location, in: matches)
            } else if textChanged, currentMatchIndex >= matches.count {
                currentMatchIndex = max(0, matches.count - 1)
            } else if navigationChanged {
                switch request.navigationDirection {
                case .next:
                    currentMatchIndex = (currentMatchIndex + 1) % matches.count
                case .previous:
                    currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
                }
            } else if currentMatchIndex >= matches.count {
                currentMatchIndex = 0
            }

            if queryChanged || textChanged || !rangesEqual(highlightedRanges, matches) || lastHighlightTheme != highlightTheme {
                applySearchHighlights(matches: matches, currentIndex: currentMatchIndex, theme: theme, in: textView)
            } else if navigationChanged || previousMatchIndex != currentMatchIndex {
                updateCurrentSearchHighlight(
                    previousIndex: previousMatchIndex,
                    currentIndex: currentMatchIndex,
                    matches: matches,
                    theme: theme,
                    in: textView
                )
            }

            if queryChanged || navigationChanged {
                let range = matches[currentMatchIndex]
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
            }

            lastSearchQuery = query
            lastSearchOptions = options
            lastSearchedText = text
            lastNavigationSerial = request.navigationSerial

            return DocumentSearchResult(
                currentIndex: currentMatchIndex + 1,
                totalCount: matches.count
            )
        }

        private func matchRanges(
            for query: String,
            options: MonknotSearchOptions,
            in text: String
        ) -> [NSRange] {
            MonknotTextSearch.matchingRanges(of: query, in: text, options: options)
        }

        private func firstMatchIndex(atOrAfter location: Int, in matches: [NSRange]) -> Int {
            matches.firstIndex { $0.location >= location } ?? 0
        }

        private func applySearchHighlights(
            matches: [NSRange],
            currentIndex: Int,
            theme: AppTheme,
            in textView: NSTextView
        ) {
            clearSearchHighlights(in: textView, resetMatches: false)

            guard let layoutManager = textView.layoutManager else { return }
            let accent = NSColor(hex: theme.accent)
            let matchColor = accent.withAlphaComponent(theme.isDark ? 0.24 : 0.18)
            let currentColor = accent.withAlphaComponent(theme.isDark ? 0.44 : 0.30)

            for (index, range) in matches.enumerated() {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: index == currentIndex ? currentColor : matchColor,
                    forCharacterRange: range
                )
            }

            highlightedRanges = matches
            lastHighlightTheme = SearchHighlightTheme(theme: theme)
        }

        private func updateCurrentSearchHighlight(
            previousIndex: Int,
            currentIndex: Int,
            matches: [NSRange],
            theme: AppTheme,
            in textView: NSTextView
        ) {
            guard let layoutManager = textView.layoutManager else { return }
            guard previousIndex >= 0, previousIndex < matches.count else { return }
            guard currentIndex >= 0, currentIndex < matches.count else { return }

            let accent = NSColor(hex: theme.accent)
            let matchColor = accent.withAlphaComponent(theme.isDark ? 0.24 : 0.18)
            let currentColor = accent.withAlphaComponent(theme.isDark ? 0.44 : 0.30)

            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: matchColor,
                forCharacterRange: matches[previousIndex]
            )
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: currentColor,
                forCharacterRange: matches[currentIndex]
            )
            lastHighlightTheme = SearchHighlightTheme(theme: theme)
        }

        private func clearSearchHighlights(in textView: NSTextView, resetMatches: Bool = true) {
            guard let layoutManager = textView.layoutManager else {
                highlightedRanges = []
                if resetMatches {
                    searchMatches = []
                }
                return
            }

            let length = (textView.string as NSString).length
            for range in highlightedRanges {
                guard range.location >= 0, NSMaxRange(range) <= length else { continue }
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
            highlightedRanges = []
            if resetMatches {
                searchMatches = []
            }
            lastHighlightTheme = nil
        }

        private func rangesEqual(_ lhs: [NSRange], _ rhs: [NSRange]) -> Bool {
            guard lhs.count == rhs.count else { return false }
            return zip(lhs, rhs).allSatisfy { left, right in
                left.location == right.location && left.length == right.length
            }
        }

        private static func boundedRange(_ range: NSRange, in text: String) -> NSRange {
            let length = (text as NSString).length
            let location = max(0, min(range.location, length))
            let requestedUpperBound = range.location > Int.max - range.length
                ? Int.max
                : range.location + range.length
            let upperBound = max(location, min(requestedUpperBound, length))
            return NSRange(location: location, length: upperBound - location)
        }

        private struct SearchHighlightTheme: Equatable {
            let accent: String
            let isDark: Bool

            init(theme: AppTheme) {
                self.accent = theme.accent
                self.isDark = theme.isDark
            }
        }
    }
}

enum MarkdownSyntaxStyle: Equatable {
    case heading
    case quote
    case strong
    case wikilink
    case link
    case code
}

struct MarkdownSyntaxToken: Equatable {
    let range: NSRange
    let style: MarkdownSyntaxStyle
}

enum MarkdownSyntaxTokenizer {
    private struct Pattern {
        let expression: NSRegularExpression
        let style: MarkdownSyntaxStyle
    }

    private static let patterns: [Pattern] = [
        Pattern(
            expression: try! NSRegularExpression(pattern: #"(?m)^ {0,3}>.*$"#),
            style: .quote
        ),
        Pattern(
            expression: try! NSRegularExpression(pattern: #"(?m)^ {0,3}#{1,6}[\t ]+.*$"#),
            style: .heading
        ),
        Pattern(
            expression: try! NSRegularExpression(pattern: #"(?:\*\*[^*\n]+\*\*|__[^_\n]+__)"#),
            style: .strong
        ),
        Pattern(
            expression: try! NSRegularExpression(pattern: #"\[\[[^\]\n]+\]\]"#),
            style: .wikilink
        ),
        Pattern(
            expression: try! NSRegularExpression(pattern: #"\[[^\]\n]+\]\([^\)\n]+\)"#),
            style: .link
        ),
        Pattern(
            expression: try! NSRegularExpression(pattern: #"`[^`\n]+`"#),
            style: .code
        )
    ]

    static func tokens(in source: String) -> [MarkdownSyntaxToken] {
        let range = NSRange(location: 0, length: (source as NSString).length)
        return patterns.flatMap { pattern in
            pattern.expression.matches(in: source, range: range).map {
                MarkdownSyntaxToken(range: $0.range, style: pattern.style)
            }
        }
    }
}

enum MarkdownEditorLayout {
    static func lineHeight(forFontSize fontSize: CGFloat) -> CGFloat {
        max(22, ceil(fontSize * 1.45))
    }
}

private enum MarkdownSyntaxHighlighter {
    static func apply(
        _ source: String,
        enabled: Bool,
        theme: AppTheme,
        font: NSFont,
        to textView: NSTextView
    ) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let paragraphStyle = NSMutableParagraphStyle()
        if enabled {
            let lineHeight = MarkdownEditorLayout.lineHeight(forFontSize: font.pointSize)
            paragraphStyle.minimumLineHeight = lineHeight
            paragraphStyle.maximumLineHeight = lineHeight
        }

        let primary = NSColor(hex: theme.foreground)
        let baseColor = enabled ? primary.withAlphaComponent(0.62) : primary
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: baseColor,
            .paragraphStyle: paragraphStyle
        ]

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: fullRange)

        if enabled {
            let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            for token in MarkdownSyntaxTokenizer.tokens(in: source) {
                let attributes: [NSAttributedString.Key: Any]
                switch token.style {
                case .heading:
                    attributes = [
                        .font: boldFont,
                        .foregroundColor: NSColor(hex: theme.accent)
                    ]
                case .quote:
                    attributes = [.foregroundColor: primary.withAlphaComponent(0.40)]
                case .strong:
                    attributes = [
                        .font: boldFont,
                        .foregroundColor: primary
                    ]
                case .wikilink:
                    attributes = [.foregroundColor: NSColor(hex: theme.semanticColors.skill)]
                case .link:
                    attributes = [.foregroundColor: NSColor(hex: theme.accent)]
                case .code:
                    attributes = [.foregroundColor: NSColor(hex: theme.accent).withAlphaComponent(0.88)]
                }
                storage.addAttributes(attributes, range: token.range)
            }
        }
        storage.endEditing()
        textView.typingAttributes = baseAttributes
    }
}

private struct MarkdownTextCommandResult {
    let replacementRange: NSRange
    let replacementText: String
    let selectedRange: NSRange
}

private enum MarkdownTextCommandApplier {
    static func apply(
        _ command: MarkdownTextEditorCommand,
        to text: String,
        selectedRange: NSRange
    ) -> MarkdownTextCommandResult {
        let range = boundedRange(selectedRange, in: text)

        switch command {
        case .paragraph:
            return replaceSelectedLines(in: text, selectedRange: range) { lines in
                lines.map(removeBlockPrefix(_:))
            }
        case .heading(let level):
            return replaceSelectedLines(in: text, selectedRange: range) { lines in
                let prefix = String(repeating: "#", count: max(1, min(level, 6))) + " "
                return lines.map { prefix + removeBlockPrefix($0) }
            }
        case .bold:
            return wrapSelection(in: text, range: range, prefix: "**", suffix: "**", placeholder: "bold")
        case .italic:
            return wrapSelection(in: text, range: range, prefix: "*", suffix: "*", placeholder: "italic")
        case .quote:
            return replaceSelectedLines(in: text, selectedRange: range) { lines in
                lines.map {
                    let line = removeBlockPrefix($0)
                    return line.isEmpty ? "> " : "> \(line)"
                }
            }
        case .code:
            return range.length == 0 || !selectedText(in: text, range: range).containsNewline
                ? wrapSelection(in: text, range: range, prefix: "`", suffix: "`", placeholder: "code")
                : insertBlock("```\n\(selectedText(in: text, range: range))\n```", in: text, range: range)
        case .link:
            let label = range.length > 0 ? selectedText(in: text, range: range) : "link text"
            let replacement = "[\(label)](https://)"
            let urlLocation = range.location + label.utf16.count + 3
            return MarkdownTextCommandResult(
                replacementRange: range,
                replacementText: replacement,
                selectedRange: NSRange(location: urlLocation, length: "https://".utf16.count)
            )
        case .bulletList:
            return replaceSelectedLines(in: text, selectedRange: range) { lines in
                lines.map {
                    let line = removeBlockPrefix($0)
                    return line.isEmpty ? "- " : "- \(line)"
                }
            }
        case .numberedList:
            return replaceSelectedLines(in: text, selectedRange: range) { lines in
                lines.enumerated().map { index, line in
                    let line = removeBlockPrefix(line)
                    return line.isEmpty ? "\(index + 1). " : "\(index + 1). \(line)"
                }
            }
        case .taskList:
            return replaceSelectedLines(in: text, selectedRange: range) { lines in
                lines.map {
                    let line = removeBlockPrefix($0)
                    return line.isEmpty ? "- [ ] " : "- [ ] \(line)"
                }
            }
        case .image:
            let replacement = "![alt text](url)"
            return MarkdownTextCommandResult(
                replacementRange: range,
                replacementText: replacement,
                selectedRange: NSRange(location: range.location + 2, length: "alt text".utf16.count)
            )
        case .horizontalRule:
            return insertBlock("---", in: text, range: range)
        }
    }

    private static func wrapSelection(
        in text: String,
        range: NSRange,
        prefix: String,
        suffix: String,
        placeholder: String
    ) -> MarkdownTextCommandResult {
        if range.length > 0,
           let result = unwrapSelectionIfNeeded(in: text, range: range, prefix: prefix, suffix: suffix) {
            return result
        }

        let body = range.length > 0 ? selectedText(in: text, range: range) : placeholder
        let replacement = prefix + body + suffix
        return MarkdownTextCommandResult(
            replacementRange: range,
            replacementText: replacement,
            selectedRange: NSRange(location: range.location + prefix.utf16.count, length: body.utf16.count)
        )
    }

    private static func unwrapSelectionIfNeeded(
        in text: String,
        range: NSRange,
        prefix: String,
        suffix: String
    ) -> MarkdownTextCommandResult? {
        let nsText = text as NSString
        let prefixLength = (prefix as NSString).length
        let suffixLength = (suffix as NSString).length
        let selected = nsText.substring(with: range)

        if selected.hasPrefix(prefix),
           selected.hasSuffix(suffix),
           (selected as NSString).length >= prefixLength + suffixLength {
            let bodyRange = NSRange(
                location: prefixLength,
                length: (selected as NSString).length - prefixLength - suffixLength
            )
            let body = (selected as NSString).substring(with: bodyRange)
            return MarkdownTextCommandResult(
                replacementRange: range,
                replacementText: body,
                selectedRange: NSRange(location: range.location, length: (body as NSString).length)
            )
        }

        let prefixRange = NSRange(location: range.location - prefixLength, length: prefixLength)
        let suffixRange = NSRange(location: NSMaxRange(range), length: suffixLength)
        guard range.location >= prefixLength,
              NSMaxRange(suffixRange) <= nsText.length,
              nsText.substring(with: prefixRange) == prefix,
              nsText.substring(with: suffixRange) == suffix else {
            return nil
        }

        return MarkdownTextCommandResult(
            replacementRange: NSRange(location: prefixRange.location, length: prefixLength + range.length + suffixLength),
            replacementText: selected,
            selectedRange: NSRange(location: prefixRange.location, length: range.length)
        )
    }

    private static func insertBlock(_ block: String, in text: String, range: NSRange) -> MarkdownTextCommandResult {
        let nsText = text as NSString
        let leading = range.location > 0 && !nsText.substring(to: range.location).hasSuffix("\n\n")
            ? (nsText.substring(to: range.location).hasSuffix("\n") ? "\n" : "\n\n")
            : ""
        let trailingLocation = min(nsText.length, NSMaxRange(range))
        let trailing = trailingLocation < nsText.length && !nsText.substring(from: trailingLocation).hasPrefix("\n\n")
            ? (nsText.substring(from: trailingLocation).hasPrefix("\n") ? "\n" : "\n\n")
            : ""
        let replacement = leading + block + trailing
        let selectionLocation = range.location + leading.utf16.count + block.utf16.count
        return MarkdownTextCommandResult(
            replacementRange: range,
            replacementText: replacement,
            selectedRange: NSRange(location: selectionLocation, length: 0)
        )
    }

    private static func replaceSelectedLines(
        in text: String,
        selectedRange: NSRange,
        transform: ([String]) -> [String]
    ) -> MarkdownTextCommandResult {
        let nsText = text as NSString
        let sourceRange = lineRange(for: selectedRange, in: nsText)
        let source = nsText.substring(with: sourceRange)
        let hasTrailingNewline = source.hasSuffix("\n")
        var lines = source.components(separatedBy: "\n")
        if hasTrailingNewline {
            lines.removeLast()
        }

        let replacement = transform(lines).joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        return MarkdownTextCommandResult(
            replacementRange: sourceRange,
            replacementText: replacement,
            selectedRange: NSRange(location: sourceRange.location, length: replacement.utf16.count)
        )
    }

    private static func removeBlockPrefix(_ line: String) -> String {
        let pattern = #"^\s{0,3}(#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+|\d+[.)][ \t]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return line
        }

        let range = NSRange(location: 0, length: (line as NSString).length)
        return expression.stringByReplacingMatches(in: line, range: range, withTemplate: "")
    }

    private static func lineRange(for range: NSRange, in text: NSString) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let location = max(0, min(range.location, text.length))
        let length = max(0, min(range.length, text.length - location))
        return text.lineRange(for: NSRange(location: location, length: length))
    }

    private static func selectedText(in text: String, range: NSRange) -> String {
        (text as NSString).substring(with: boundedRange(range, in: text))
    }

    private static func boundedRange(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = max(0, min(range.location, length))
        let upperBound = max(location, min(range.location + range.length, length))
        return NSRange(location: location, length: upperBound - location)
    }
}

private extension String {
    var containsNewline: Bool {
        contains("\n") || contains("\r")
    }
}

private final class EditorFlowReviewViewController: NSViewController {
    private let suggestion: EditorFlowSuggestion
    private let editorFont: NSFont
    private let zoomScale: CGFloat
    private let onReplace: () -> Void
    private let onCancel: () -> Void
    private var replaceButton: NSButton?

    init(
        suggestion: EditorFlowSuggestion,
        editorFont: NSFont,
        zoomScale: CGFloat,
        onReplace: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.suggestion = suggestion
        self.editorFont = editorFont
        self.zoomScale = max(0.1, zoomScale)
        self.onReplace = onReplace
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        let scale = zoomScale
        let count = suggestion.edits.count
        let title = NSTextField(labelWithString: "Review \(count) \(count == 1 ? "change" : "changes")")
        title.font = .systemFont(ofSize: 13 * scale, weight: .semibold)
        title.textColor = .labelColor
        title.setAccessibilityLabel(title.stringValue)

        let changeLabels = suggestion.edits.map { edit -> NSTextField in
            let label = NSTextField(labelWithString: "\(edit.originalText) → \(edit.replacementText)")
            label.font = editorFont
            label.textColor = .labelColor
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.cell?.wraps = true
            label.setAccessibilityLabel(
                "Replace “\(edit.originalText)” with “\(edit.replacementText)”."
            )
            return label
        }

        let changes = NSStackView(views: changeLabels)
        changes.orientation = .vertical
        changes.alignment = .leading
        changes.spacing = 8 * scale

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelReview(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityLabel("Cancel correction")
        let replace = NSButton(title: "Replace", target: self, action: #selector(replaceText(_:)))
        replace.bezelStyle = .rounded
        replace.keyEquivalent = "\r"
        replace.setAccessibilityLabel(
            count == 1 ? "Replace text" : "Replace text with \(count) reviewed changes"
        )
        replaceButton = replace

        let buttons = NSStackView(views: [cancel, replace])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8 * scale

        let content = NSStackView(views: [title, changes, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12 * scale
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        let longestChangeWidth = suggestion.fullChangeRows.map {
            ($0 as NSString).size(withAttributes: [.font: editorFont]).width
        }.max() ?? 0
        let horizontalInset = 16 * scale
        let verticalInset = 14 * scale
        let width = min(
            520 * scale,
            max(280 * scale, ceil(longestChangeWidth) + horizontalInset * 2)
        )
        for label in changeLabels {
            label.preferredMaxLayoutWidth = width - horizontalInset * 2
        }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: width),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -horizontalInset),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: verticalInset),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -verticalInset),
        ])
        self.view = root
        preferredContentSize = NSSize(
            width: width,
            height: max(112 * scale, ceil(content.fittingSize.height) + verticalInset * 2)
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let replaceButton {
            view.window?.makeFirstResponder(replaceButton)
        }
    }

    @objc private func replaceText(_ sender: Any?) {
        onReplace()
    }

    @objc private func cancelReview(_ sender: Any?) {
        onCancel()
    }
}

class MarkdownNSTextView: NSTextView, NSPopoverDelegate {
    var markdownShortcutsEnabled = false
    var flowSourceMode: FlowSourceMode?
    private var inlinePredictionsPreferenceEnabled = false
    private(set) var flowWritingToolsReady = false
    private(set) var flowWritingToolsInvocationEligible = false
    var wikilinkDocuments: [WorkspaceDocument] = []
    var commandHandler: ((MarkdownTextEditorCommand) -> Bool)?
    var workspaceLinkHandler: ((MarkdownWorkspaceLink) -> Bool)?
    var inspectLinksHandler: (() -> Void)?
    var imagePasteHandler: ((NSImage) -> Bool)?
    var fileDropHandler: (([URL], Int) -> Bool)?
    var flowSuggestionAcceptanceHandler: ((EditorFlowSuggestion) -> Bool)?
    var flowSuggestionDismissalHandler: (() -> Void)?
    var flowSuggestionCancellationHandler: (() -> Void)?
    var writingToolsRequestHandler: (() -> Bool)?
    var flowSuggestion: EditorFlowSuggestion? {
        didSet {
            guard flowSuggestion != oldValue else { return }
            closeFlowReviewPopover(restoreEditorFocus: false)
            needsDisplay = true
            setAccessibilityHelp(flowSuggestion?.accessibilityText)
            refreshFlowAccessibilityActions()
            if let flowSuggestion {
                NSAccessibility.post(
                    element: self,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: flowSuggestion.accessibilityText,
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                    ]
                )
            }
        }
    }
    fileprivate var flowCuePalette = EditorFlowCuePalette.native {
        didSet { needsDisplay = true }
    }
    private var flowReviewPopover: NSPopover?
    var isFlowReviewPopoverShown: Bool {
        flowReviewPopover?.isShown == true
    }

    // AppKit's text dragging contract uses acceptableDragTypes and the NSDraggingDestination
    // lifecycle. See https://developer.apple.com/documentation/appkit/nstextview/acceptabledragtypes
    // and https://developer.apple.com/documentation/appkit/nsdraggingdestination.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        let inherited = super.acceptableDragTypes
        guard fileDropHandler != nil else { return inherited }
        return inherited.contains(.fileURL) ? inherited : inherited + [.fileURL]
    }
    var zoomScale = WorkspaceZoomPolicy.defaultValue {
        didSet {
            guard zoomScale != oldValue else { return }
            refreshContentWidthLayout()
        }
    }
    var contentWidthPercent = ContentWidthPreference.defaultValue {
        didSet {
            guard contentWidthPercent != oldValue else { return }
            refreshContentWidthLayout()
        }
    }
    private var wikilinkSuggestionIndex = 0
    private var lastWikilinkPartial = ""
    var fontSmoothingEnabled = true {
        didSet {
            guard fontSmoothingEnabled != oldValue else { return }
            needsDisplay = true
        }
    }

    func applyTextChecking(_ options: EditorTextCheckingOptions) {
        // NSTextView owns native spelling and grammar state. These are the only enabled
        // text-checking behaviors; Monknot never rewrites Markdown automatically.
        // https://developer.apple.com/documentation/appkit/nstextview/iscontinuousspellcheckingenabled
        // https://developer.apple.com/documentation/appkit/nstextview/isgrammarcheckingenabled
        let nativeCheckingEnabled = flowSourceMode != nil
        isContinuousSpellCheckingEnabled = nativeCheckingEnabled && options.checksSpelling
        isGrammarCheckingEnabled = nativeCheckingEnabled && options.checksGrammar
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        inlinePredictionsPreferenceEnabled = options.inlinePredictions
        if flowSourceMode == nil || !options.inlinePredictions {
            inlinePredictionType = .no
        }
    }

    override func checkSpelling(_ sender: Any?) {
        if #available(macOS 15.0, *), isWritingToolsActive { return }
        guard flowSourceMode != nil else { return }
        // The legacy spelling-panel action searches the receiver without a
        // result-filtering callback. Route it through AppKit's modern checking
        // pipeline so the delegate can remove code/link results.
        checkTextInDocument(sender)
    }

    func applyInlinePredictionEligibility(_ isEligible: Bool) {
        inlinePredictionType = flowSourceMode != nil
            && inlinePredictionsPreferenceEnabled
            && isEligible
            ? .default
            : .no
    }

    func applyWritingTools(
        _ mode: FlowSourceMode?,
        protectedRangesReady: Bool,
        invocationEligible: Bool = true
    ) {
        flowWritingToolsReady = mode != nil && protectedRangesReady
        flowWritingToolsInvocationEligible = flowWritingToolsReady && invocationEligible
        if #available(macOS 15.0, *) {
            writingToolsBehavior = flowWritingToolsInvocationEligible ? .limited : .none
            allowedWritingToolsResultOptions = [.plainText]
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshContentWidthLayout()
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder === self,
           !isFlowReviewPopoverShown,
           let suggestion = flowSuggestion,
           let geometry = flowCueGeometry(for: suggestion) {
            let point = convert(event.locationInWindow, from: nil)
            if geometry.rect.contains(point) {
                if !showFlowReviewPopover(for: suggestion) {
                    NSSound.beep()
                }
                return
            }
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.clickCount == 1,
           modifiers.contains(.command),
           let offset = utf16Offset(at: event.locationInWindow),
           activateMarkdownLink(atUTF16Offset: offset) {
            return
        }
        super.mouseDown(with: event)
    }

    @discardableResult
    func activateMarkdownLink(atUTF16Offset offset: Int) -> Bool {
        guard let workspaceLinkHandler,
              let link = MarkdownWorkspaceLinkParser().link(atUTF16Offset: offset, in: string),
              link.kind == .markdown || link.kind == .wikilink || link.kind == .referenceUsage
        else { return false }
        return workspaceLinkHandler(link)
    }

    @discardableResult
    func requestImagePaste(from pasteboard: NSPasteboard) -> Bool {
        guard let imagePasteHandler, let image = Self.image(from: pasteboard) else { return false }
        return imagePasteHandler(image)
    }

    private static func image(from pasteboard: NSPasteboard) -> NSImage? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                return image
            }
        }
        return NSImage(pasteboard: pasteboard)
    }

    override func paste(_ sender: Any?) {
        if requestImagePaste(from: .general) {
            return
        }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(from: sender).isEmpty == false && fileDropHandler != nil
            ? .copy
            : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(from: sender).isEmpty == false && fileDropHandler != nil
            ? .copy
            : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        droppedFileURLs(from: sender).isEmpty == false && fileDropHandler != nil
            ? true
            : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(from: sender)
        guard !urls.isEmpty, let fileDropHandler else {
            return super.performDragOperation(sender)
        }
        let point = convert(sender.draggingLocation, from: nil)
        // NSTextView defines this API as the insertion position for a point in view coordinates.
        // https://developer.apple.com/documentation/appkit/nstextview/characterindexforinsertion(at:)
        let offset = characterIndexForInsertion(at: point)
        return fileDropHandler(urls, offset)
    }

    private func droppedFileURLs(from sender: NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        return objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let sourceLength = (string as NSString).length
        if sourceLength > 0 {
            let localPoint = convert(event.locationInWindow, from: nil)
            let offset = min(characterIndexForInsertion(at: localPoint), sourceLength - 1)
            let clickedRange = NSRange(location: max(0, offset), length: 1)
            let allowsNativeChecking = (delegate as? MarkdownTextEditor.Coordinator)?
                .nativeTextCheckingAllows(clickedRange) == true
            if !allowsNativeChecking {
                Self.removeNativeSpellingItems(from: menu)
            }
        } else {
            Self.removeNativeSpellingItems(from: menu)
        }
        if #available(macOS 15.2, *) {
            menu.automaticallyInsertsWritingToolsItems = flowWritingToolsInvocationEligible
        }
        var addedCustomItem = false

        func addSeparatorIfNeeded() {
            guard !addedCustomItem else { return }
            menu.addItem(.separator())
            addedCustomItem = true
        }

        if inspectLinksHandler != nil,
           menu.items.contains(where: { $0.action == #selector(inspectLinks(_:)) }) == false {
            addSeparatorIfNeeded()
            let item = NSMenuItem(
                title: "Inspect Links",
                action: #selector(inspectLinks(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }

        if selectedRange().length > 0,
           menu.items.contains(where: { $0.action == #selector(copyRenderedMarkdown(_:)) }) == false {
            addSeparatorIfNeeded()
            let item = NSMenuItem(
                title: "Copy Rendered",
                action: #selector(copyRenderedMarkdown(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    static func removeNativeSpellingItems(from menu: NSMenu) {
        let spellingActions: Set<String> = [
            "changeSpelling:",
            "ignoreSpelling:",
            "learnWord:",
            "unlearnWord:",
            "checkSpelling:",
            "checkTextInDocument:",
            "showGuessPanel:",
        ]
        for item in menu.items.reversed() {
            if let submenu = item.submenu {
                removeNativeSpellingItems(from: submenu)
                if submenu.items.isEmpty {
                    menu.removeItem(item)
                    continue
                }
            }
            guard let action = item.action,
                  spellingActions.contains(NSStringFromSelector(action))
            else { continue }
            menu.removeItem(item)
        }
        while menu.items.first?.isSeparatorItem == true {
            menu.removeItem(at: 0)
        }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
        var index = menu.items.count - 1
        while index > 0 {
            if menu.items[index].isSeparatorItem,
               menu.items[index - 1].isSeparatorItem {
                menu.removeItem(at: index)
            }
            index -= 1
        }
    }

    @objc func inspectLinks(_ sender: Any?) {
        inspectLinksHandler?()
    }

    @objc func copyRenderedMarkdown(_ sender: Any?) {
        do {
            _ = try copyRenderedMarkdown(to: .general)
        } catch {
            NSSound.beep()
        }
    }

    @MainActor
    @discardableResult
    func copyRenderedMarkdown(to pasteboard: NSPasteboard) throws -> Bool {
        guard let markdown = selectedMarkdownForRenderedCopy() else { return false }
        return try MarkdownSemanticPasteboardExportService.copy(markdown, to: pasteboard)
    }

    func selectedMarkdownForRenderedCopy() -> String? {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return nil }
        return (string as NSString).substring(with: range)
    }

    private func utf16Offset(at windowPoint: NSPoint) -> Int? {
        guard let layoutManager,
              let textContainer,
              layoutManager.numberOfGlyphs > 0
        else { return nil }

        let localPoint = convert(windowPoint, from: nil)
        let containerOrigin = textContainerOrigin
        let containerPoint = NSPoint(
            x: localPoint.x - containerOrigin.x,
            y: localPoint.y - containerOrigin.y
        )
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        ).insetBy(dx: -2, dy: -2)
        guard glyphRect.contains(containerPoint) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }

    func refreshContentWidthLayout() {
        textContainer?.lineFragmentPadding = ContentWidthPreference.editorLineFragmentPadding(
            zoomScale: zoomScale
        )
        textContainerInset = NSSize(
            width: ContentWidthPreference.editorHorizontalInset(
                viewportWidth: bounds.width,
                contentWidthPercent: contentWidthPercent,
                zoomScale: zoomScale
            ),
            height: ContentWidthPreference.editorVerticalInset(zoomScale: zoomScale)
        )
    }

    override func keyDown(with event: NSEvent) {
        if #available(macOS 15.0, *), isWritingToolsActive {
            super.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock])
        if let flowSuggestion,
           (event.keyCode == 36 || event.keyCode == 76),
           modifiers == [.option] {
            if !showFlowReviewPopover(for: flowSuggestion) {
                NSSound.beep()
            }
            return
        }
        if event.keyCode == 48, modifiers.isEmpty {
            if completeActiveWikilink() {
                return
            }
            if markdownShortcutsEnabled,
               let listCommand = markdownListCommand(for: event),
               performMarkdownListEdit(listCommand) {
                return
            }
            if let flowSuggestion {
                if flowCueLayout(for: flowSuggestion).mode == .review {
                    if !showFlowReviewPopover(for: flowSuggestion) {
                        NSSound.beep()
                    }
                    return
                }
                if flowSuggestionAcceptanceHandler?(flowSuggestion) == true {
                    return
                }
            }
        } else if event.keyCode == 53, modifiers.isEmpty, flowSuggestion != nil {
            flowSuggestionDismissalHandler?()
            return
        } else {
            flowSuggestionDismissalHandler?()
        }

        if markdownShortcutsEnabled,
           let listCommand = markdownListCommand(for: event),
           performMarkdownListEdit(listCommand) {
            return
        }

        guard markdownShortcutsEnabled,
              let command = markdownCommand(for: event),
              commandHandler?(command) == true
        else {
            super.keyDown(with: event)
            return
        }
    }

    @discardableResult
    func performMarkdownListEdit(_ command: MarkdownListEditCommand) -> Bool {
        guard isEditable,
              let textStorage,
              let plan = MarkdownListEditPlanner.plan(
                command,
                in: string,
                selectedRange: selectedRange()
              ),
              shouldChangeText(in: plan.replacementRange, replacementString: plan.replacementText)
        else { return false }

        let completedSentenceEnd = command == .newline && plan.replacementRange.length == 0
            ? plan.replacementRange.location
            : nil
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        textStorage.replaceCharacters(in: plan.replacementRange, with: plan.replacementText)
        didChangeText()
        setSelectedRange(plan.selectedRange)
        scrollRangeToVisible(plan.selectedRange)
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(listActionName(command))
        breakUndoCoalescing()
        if let completedSentenceEnd {
            (delegate as? MarkdownTextEditor.Coordinator)?
                .scheduleCompletedSentenceFlowCheck(endingAt: completedSentenceEnd)
        }
        return true
    }

    @discardableResult
    private func completeActiveWikilink() -> Bool {
        let cursor = selectedRange().location + selectedRange().length
        guard let context = WikilinkAutocompleteService.activeCompletion(in: string, cursorUTF16Offset: cursor) else {
            resetWikilinkSuggestionCycle()
            return false
        }

        let suggestions = WikilinkAutocompleteService.suggestions(
            partial: context.partialText,
            documents: wikilinkDocuments
        )
        guard !suggestions.isEmpty else {
            resetWikilinkSuggestionCycle()
            return false
        }

        if context.partialText != lastWikilinkPartial {
            wikilinkSuggestionIndex = 0
            lastWikilinkPartial = context.partialText
        } else {
            wikilinkSuggestionIndex = (wikilinkSuggestionIndex + 1) % suggestions.count
        }

        let suggestion = suggestions[wikilinkSuggestionIndex]
        let replacement = suggestion + "]]"
        let replaceRange = NSRange(location: context.replaceRangeLocation, length: context.replaceRangeLength)
        guard let textStorage = textStorage else { return false }

        if shouldChangeText(in: replaceRange, replacementString: replacement) {
            textStorage.replaceCharacters(in: replaceRange, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: replaceRange.location + (replacement as NSString).length, length: 0))
        }

        return true
    }

    private func resetWikilinkSuggestionCycle() {
        wikilinkSuggestionIndex = 0
        lastWikilinkPartial = ""
    }

    private func markdownListCommand(for event: NSEvent) -> MarkdownListEditCommand? {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock])
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty {
            return .newline
        }
        guard event.keyCode == 48 else { return nil }
        if modifiers.isEmpty { return .indent }
        if modifiers == [.shift] { return .outdent }
        return nil
    }

    private func listActionName(_ command: MarkdownListEditCommand) -> String {
        switch command {
        case .newline: return "Continue List"
        case .indent: return "Indent List"
        case .outdent: return "Outdent List"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else {
            super.draw(dirtyRect)
            return
        }

        let previousAntialiasing = context.shouldAntialias
        context.shouldAntialias = fontSmoothingEnabled
        super.draw(dirtyRect)
        drawFlowSuggestionIfNeeded(in: dirtyRect)
        context.shouldAntialias = previousAntialiasing
    }

    override func resignFirstResponder() -> Bool {
        if flowReviewPopover == nil {
            flowSuggestionCancellationHandler?()
        }
        return super.resignFirstResponder()
    }

    @discardableResult
    private func showFlowReviewPopover(for suggestion: EditorFlowSuggestion) -> Bool {
        guard flowSuggestion == suggestion,
              window != nil,
              let geometry = flowCueGeometry(for: suggestion)
        else { return false }
        if flowReviewPopover?.isShown == true {
            return true
        }

        closeFlowReviewPopover(restoreEditorFocus: false)
        let controller = EditorFlowReviewViewController(
            suggestion: suggestion,
            editorFont: font
                ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            zoomScale: max(0.1, zoomScale),
            onReplace: { [weak self] in
                guard let self else { return }
                let accepted = self.flowSuggestionAcceptanceHandler?(suggestion) == true
                self.closeFlowReviewPopover(restoreEditorFocus: true)
                if !accepted {
                    NSSound.beep()
                }
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.flowSuggestionDismissalHandler?()
                self.closeFlowReviewPopover(restoreEditorFocus: true)
            }
        )
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = controller
        popover.delegate = self
        flowReviewPopover = popover
        popover.show(relativeTo: geometry.rect, of: self, preferredEdge: .maxY)
        return popover.isShown
    }

    private func closeFlowReviewPopover(restoreEditorFocus: Bool) {
        let popover = flowReviewPopover
        flowReviewPopover = nil
        popover?.close()
        if restoreEditorFocus {
            window?.makeFirstResponder(self)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
              closedPopover === flowReviewPopover
        else { return }
        flowReviewPopover = nil
        if window?.firstResponder !== self {
            flowSuggestionCancellationHandler?()
        }
    }

    private func refreshFlowAccessibilityActions() {
        guard let suggestion = flowSuggestion else {
            setAccessibilityCustomActions(nil)
            return
        }
        let changes = suggestion.exactChangeDescription
        let accept = NSAccessibilityCustomAction(
            name: "Accept correction: \(changes)",
            handler: { [weak self] in
                guard let self, self.flowSuggestion == suggestion else { return false }
                return self.flowSuggestionAcceptanceHandler?(suggestion) == true
            }
        )
        let dismiss = NSAccessibilityCustomAction(
            name: "Dismiss correction: \(changes)",
            handler: { [weak self] in
                guard let self, self.flowSuggestion == suggestion else { return false }
                self.flowSuggestionDismissalHandler?()
                return true
            }
        )
        let review = NSAccessibilityCustomAction(
            name: "Review correction: \(changes)",
            handler: { [weak self] in
                self?.showFlowReviewPopover(for: suggestion) == true
            }
        )
        setAccessibilityCustomActions([accept, dismiss, review])
    }

    private func drawFlowSuggestionIfNeeded(in dirtyRect: NSRect) {
        guard let suggestion = flowSuggestion,
              window?.firstResponder === self,
              !isFlowReviewPopoverShown,
              selectedRange() == suggestion.selectedRange,
              suggestion.caretUTF16Offset <= (string as NSString).length,
              let geometry = flowCueGeometry(for: suggestion)
        else { return }

        let layout = geometry.layout
        let drawRect = geometry.rect
        guard drawRect.insetBy(dx: -28, dy: -28).intersects(dirtyRect) else { return }
        drawFlowCueSurface(in: drawRect, cornerRadius: layout.cornerRadius)

        for (index, row) in layout.rows.enumerated() {
            let rendered = attributedFlowCueRow(
                row,
                includesTabHint: index == layout.rows.count - 1
            )
            let contentSize = rendered.size()
            let rowRect = NSRect(
                x: drawRect.minX + layout.horizontalInset,
                y: drawRect.minY + CGFloat(index) * layout.rowHeight,
                width: drawRect.width - layout.horizontalInset * 2,
                height: layout.rowHeight
            )
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rowRect).addClip()
            rendered.draw(
                at: NSPoint(
                    x: rowRect.minX,
                    y: rowRect.midY - contentSize.height / 2
                )
            )
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    func flowCueLayout(for suggestion: EditorFlowSuggestion) -> EditorFlowCueLayout {
        let scale = max(0.1, zoomScale)
        let edgeInset = max(1, (8 * scale).rounded())
        let availableWidth = max(0, visibleRect.width - edgeInset * 2)
        let editorFont = font
            ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return EditorFlowCueLayout.make(
            for: suggestion,
            availableWidth: availableWidth,
            editorFont: editorFont,
            zoomScale: scale
        )
    }

    private func flowCueGeometry(
        for suggestion: EditorFlowSuggestion
    ) -> (layout: EditorFlowCueLayout, rect: NSRect)? {
        let layout = flowCueLayout(for: suggestion)
        guard let origin = flowSuggestionOrigin(
            atUTF16Offset: suggestion.caretUTF16Offset,
            cueSize: layout.size
        ) else { return nil }
        let edgeInset = max(1, (8 * max(0.1, zoomScale)).rounded())
        let maximumX = max(
            visibleRect.minX + edgeInset,
            visibleRect.maxX - layout.size.width - edgeInset
        )
        let drawOrigin = NSPoint(
            x: min(max(origin.x, visibleRect.minX + edgeInset), maximumX),
            y: origin.y
        )
        return (layout, NSRect(origin: drawOrigin, size: layout.size))
    }

    private func attributedFlowCueRow(
        _ row: String,
        includesTabHint: Bool
    ) -> NSAttributedString {
        let editorFont = font
            ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let rendered = NSMutableAttributedString(
            string: row,
            attributes: [
                .font: editorFont,
                .foregroundColor: flowCuePalette.primaryText,
            ]
        )
        if includesTabHint {
            rendered.append(NSAttributedString(
                string: "  Tab",
                attributes: [
                    .font: EditorFlowCueLayout.shortcutFont(scale: max(0.1, zoomScale)),
                    .foregroundColor: flowCuePalette.secondaryText,
                ]
            ))
        }
        return rendered
    }

    private func drawFlowCueSurface(in rect: NSRect, cornerRadius: CGFloat) {
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        let ambient = NSShadow()
        ambient.shadowColor = flowCuePalette.usesDarkElevation
            ? NSColor.black.withAlphaComponent(0.50)
            : flowCuePalette.primaryText.withAlphaComponent(0.08)
        ambient.shadowBlurRadius = flowCuePalette.usesDarkElevation ? 24 : 12
        ambient.shadowOffset = NSSize(
            width: 0,
            height: flowCuePalette.usesDarkElevation ? -8 : -4
        )
        NSGraphicsContext.saveGraphicsState()
        ambient.set()
        flowCuePalette.surface.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let key = NSShadow()
        key.shadowColor = flowCuePalette.usesDarkElevation
            ? NSColor.black.withAlphaComponent(0.34)
            : flowCuePalette.primaryText.withAlphaComponent(0.05)
        key.shadowBlurRadius = flowCuePalette.usesDarkElevation ? 6 : 3
        key.shadowOffset = NSSize(
            width: 0,
            height: flowCuePalette.usesDarkElevation ? -2 : -1
        )
        NSGraphicsContext.saveGraphicsState()
        key.set()
        flowCuePalette.surface.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        flowCuePalette.surface.setFill()
        path.fill()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineWidth = 1 / max(1, scale)
        flowCuePalette.ring.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }

    private func flowSuggestionOrigin(
        atUTF16Offset offset: Int,
        cueSize: NSSize
    ) -> NSPoint? {
        guard let window else { return nil }
        var actualRange = NSRange(location: NSNotFound, length: 0)
        let screenRect = firstRect(
            forCharacterRange: NSRange(location: offset, length: 0),
            actualRange: &actualRange
        )
        guard screenRect.height > 0 else { return nil }
        let windowRect = window.convertFromScreen(screenRect)
        let localRect = convert(windowRect, from: nil)
        let spacing = max(1, (6 * max(0.1, zoomScale)).rounded())
        let belowCaret = localRect.maxY + spacing
        let y = belowCaret + cueSize.height <= visibleRect.maxY
            ? belowCaret
            : max(visibleRect.minY, localRect.minY - cueSize.height - spacing)
        return NSPoint(
            x: localRect.maxX + spacing,
            y: y
        )
    }

    private func markdownCommand(for event: NSEvent) -> MarkdownTextEditorCommand? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock])
        let isCommandOnly = modifiers.isSubset(of: [.command]) && modifiers.contains(.command)
        let isCommandShift = modifiers.isSubset(of: [.command, .shift])
            && modifiers.contains(.command)
            && modifiers.contains(.shift)
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }

        if isCommandOnly {
            switch key {
            case "b": return .bold
            case "i": return .italic
            case "e": return .code
            case "k": return .link
            default: return nil
            }
        }

        if isCommandShift, key == "7" {
            return .numberedList
        }

        if isCommandShift, key == "8" {
            return .bulletList
        }

        return nil
    }
}
