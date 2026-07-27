import AppKit
import MonknotCore
import SwiftUI

struct MarkdownTextEditorCommandRequest: Equatable {
    let serial: Int
    let command: MarkdownTextEditorCommand
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

struct TypingAssistantEditorActionRequest: Equatable {
    let serial: Int
    let action: TypingAssistantEditorAction
}

enum TypingAssistantEditorAction: Equatable {
    case accept
    case dismiss
}

struct MarkdownTextEditor: NSViewRepresentable {
    let documentID: String
    @Binding var text: String
    let theme: AppTheme
    let fontSize: CGFloat
    let fontSmoothing: Bool
    let scrollPosition: DocumentScrollPosition?
    let syncScrollEnabled: Bool
    let syncScrollTargetLine: Int?
    @Binding var sourceLocation: MarkdownSourceLocation?
    @Binding var searchState: DocumentSearchState
    let onScrollPositionChange: (DocumentScrollPosition) -> Void
    let onVisibleTopLineChange: ((Int) -> Void)?
    let commandRequest: MarkdownTextEditorCommandRequest?
    let markdownShortcutsEnabled: Bool
    let wikilinkDocuments: [WorkspaceDocument]
    let typingAssistantSuggestion: TypingAssistanceSuggestion?
    let typingAssistantActionRequest: TypingAssistantEditorActionRequest?
    let onTypingEditorChange:
        ((TypingAssistanceEditorSnapshot) -> TypingAssistanceTextEdit?)?
    let onTypingSelectionChange: ((TypingAssistanceEditorSnapshot) -> Void)?
    let onTypingDismissSuggestion: (() -> Void)?
    let onTypingSuggestionApplicationFinished: ((Bool) -> Void)?
    let onTypingAutomaticApplicationFinished:
        ((TypingAssistanceEditorSnapshot, Bool) -> Void)?

    init(
        documentID: String,
        text: Binding<String>,
        theme: AppTheme,
        fontSize: CGFloat,
        fontSmoothing: Bool,
        scrollPosition: DocumentScrollPosition?,
        sourceLocation: Binding<MarkdownSourceLocation?>,
        searchState: Binding<DocumentSearchState>,
        onScrollPositionChange: @escaping (DocumentScrollPosition) -> Void,
        syncScrollEnabled: Bool = false,
        syncScrollTargetLine: Int? = nil,
        onVisibleTopLineChange: ((Int) -> Void)? = nil,
        commandRequest: MarkdownTextEditorCommandRequest? = nil,
        markdownShortcutsEnabled: Bool = false,
        wikilinkDocuments: [WorkspaceDocument] = [],
        typingAssistantSuggestion: TypingAssistanceSuggestion? = nil,
        typingAssistantActionRequest: TypingAssistantEditorActionRequest? = nil,
        onTypingEditorChange:
            ((TypingAssistanceEditorSnapshot) -> TypingAssistanceTextEdit?)? = nil,
        onTypingSelectionChange:
            ((TypingAssistanceEditorSnapshot) -> Void)? = nil,
        onTypingDismissSuggestion: (() -> Void)? = nil,
        onTypingSuggestionApplicationFinished: ((Bool) -> Void)? = nil,
        onTypingAutomaticApplicationFinished:
            ((TypingAssistanceEditorSnapshot, Bool) -> Void)? = nil
    ) {
        self.documentID = documentID
        self._text = text
        self.theme = theme
        self.fontSize = fontSize
        self.fontSmoothing = fontSmoothing
        self.scrollPosition = scrollPosition
        self.syncScrollEnabled = syncScrollEnabled
        self.syncScrollTargetLine = syncScrollTargetLine
        self._sourceLocation = sourceLocation
        self._searchState = searchState
        self.onScrollPositionChange = onScrollPositionChange
        self.onVisibleTopLineChange = onVisibleTopLineChange
        self.commandRequest = commandRequest
        self.markdownShortcutsEnabled = markdownShortcutsEnabled
        self.wikilinkDocuments = wikilinkDocuments
        self.typingAssistantSuggestion = typingAssistantSuggestion
        self.typingAssistantActionRequest = typingAssistantActionRequest
        self.onTypingEditorChange = onTypingEditorChange
        self.onTypingSelectionChange = onTypingSelectionChange
        self.onTypingDismissSuggestion = onTypingDismissSuggestion
        self.onTypingSuggestionApplicationFinished =
            onTypingSuggestionApplicationFinished
        self.onTypingAutomaticApplicationFinished =
            onTypingAutomaticApplicationFinished
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
        textView.fontSmoothingEnabled = fontSmoothing
        textView.delegate = context.coordinator
        textView.markdownShortcutsEnabled = markdownShortcutsEnabled
        textView.commandHandler = { [weak coordinator = context.coordinator] command in
            coordinator?.apply(command) ?? false
        }
        textView.typingAssistantCommandHandler = {
            [weak coordinator = context.coordinator] action in
            coordinator?.apply(action) ?? false
        }
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 24, height: 24)
        let resolvedFont = font(for: theme, size: fontSize)
        textView.font = resolvedFont
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.onScrollPositionChange = onScrollPositionChange
        context.coordinator.configureTypingAssistance(
            suggestion: typingAssistantSuggestion,
            onEditorChange: onTypingEditorChange,
            onSelectionChange: onTypingSelectionChange,
            onDismissSuggestion: onTypingDismissSuggestion,
            onSuggestionApplicationFinished:
                onTypingSuggestionApplicationFinished,
            onAutomaticApplicationFinished:
                onTypingAutomaticApplicationFinished
        )
        _ = context.coordinator.prepareForDocument(documentID, in: scrollView)
        context.coordinator.synchronizeExternalText(
            text,
            documentChanged: true
        )
        context.coordinator.attach(to: scrollView)
        applyTheme(theme, to: textView, in: scrollView)
        context.coordinator.markFontApplied(resolvedFont)
        context.coordinator.markThemeApplied(theme)
        context.coordinator.markFontSmoothingApplied(fontSmoothing)
        context.coordinator.markMarkdownShortcutsApplied(markdownShortcutsEnabled)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let didChangeDocument = context.coordinator.prepareForDocument(documentID, in: scrollView)
        context.coordinator.onScrollPositionChange = onScrollPositionChange
        context.coordinator.onVisibleTopLineChange = onVisibleTopLineChange
        context.coordinator.syncScrollEnabled = syncScrollEnabled
        context.coordinator.configureTypingAssistance(
            suggestion: typingAssistantSuggestion,
            onEditorChange: onTypingEditorChange,
            onSelectionChange: onTypingSelectionChange,
            onDismissSuggestion: onTypingDismissSuggestion,
            onSuggestionApplicationFinished:
                onTypingSuggestionApplicationFinished,
            onAutomaticApplicationFinished:
                onTypingAutomaticApplicationFinished
        )
        let visibleOrigin = scrollView.contentView.bounds.origin

        if didChangeDocument || textView.string != text {
            context.coordinator.synchronizeExternalText(
                text,
                documentChanged: didChangeDocument
            )
        }

        let resolvedFont = font(for: theme, size: fontSize)
        if context.coordinator.shouldApplyFont(resolvedFont) {
            textView.font = resolvedFont
        }
        if let textView = textView as? MarkdownNSTextView {
            if context.coordinator.shouldApplyFontSmoothing(fontSmoothing) {
                textView.fontSmoothingEnabled = fontSmoothing
            }
            if context.coordinator.shouldApplyMarkdownShortcuts(markdownShortcutsEnabled) {
                textView.markdownShortcutsEnabled = markdownShortcutsEnabled
            }
            textView.wikilinkDocuments = wikilinkDocuments
        }
        if context.coordinator.shouldApplyTheme(theme) {
            applyTheme(theme, to: textView, in: scrollView)
        }

        if let commandRequest {
            context.coordinator.apply(commandRequest)
        }
        if let typingAssistantActionRequest {
            context.coordinator.apply(typingAssistantActionRequest)
        }

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

        let searchResult = context.coordinator.applySearch(searchState, theme: theme, in: textView)
        context.coordinator.applyTypingAssistantHighlight(
            theme: theme,
            in: textView
        )
        if DocumentSearchResult(currentIndex: searchState.currentIndex, totalCount: searchState.totalCount) != searchResult {
            DispatchQueue.main.async {
                self.searchState.updateResult(searchResult)
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.publishCurrentScrollPosition()
        coordinator.detach()
    }

    private func applyTheme(_ theme: AppTheme, to textView: NSTextView, in scrollView: NSScrollView) {
        let background = NSColor(hex: theme.background)
        textView.backgroundColor = background
        scrollView.backgroundColor = background
        textView.textColor = NSColor(hex: theme.foreground)
        textView.insertionPointColor = NSColor(hex: theme.cursor)
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
        weak var textView: NSTextView? {
            didSet {
                observeUndoManager()
            }
        }
        var documentID: String?
        var onScrollPositionChange: (DocumentScrollPosition) -> Void = { _ in }
        var onVisibleTopLineChange: ((Int) -> Void)?
        var syncScrollEnabled = false
        private var lastNavigatedLocation: MarkdownSourceLocation?
        private var searchMatches: [NSRange] = []
        private var highlightedRanges: [NSRange] = []
        private var lastSearchQuery = ""
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
        private var revision = 0
        private var lastTypingAssistantActionSerial = 0
        private var typingAssistantSuggestion: TypingAssistanceSuggestion?
        private var typingAssistantHighlightedRange: NSRange?
        private var onTypingEditorChange:
            ((TypingAssistanceEditorSnapshot) -> TypingAssistanceTextEdit?)?
        private var onTypingSelectionChange:
            ((TypingAssistanceEditorSnapshot) -> Void)?
        private var onTypingDismissSuggestion: (() -> Void)?
        private var onTypingSuggestionApplicationFinished: ((Bool) -> Void)?
        private var onTypingAutomaticApplicationFinished:
            ((TypingAssistanceEditorSnapshot, Bool) -> Void)?
        private var isApplyingTypingAssistantSuggestion = false
        private var undoChangeObservers: [NSObjectProtocol] = []

        init(text: Binding<String>) {
            self._text = text
        }

        deinit {
            removeUndoManagerObservers()
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
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            removeUndoManagerObservers()
            scrollView = nil
        }

        private func observeUndoManager() {
            removeUndoManagerObservers()
            guard let undoManager = textView?.undoManager else { return }
            let center = NotificationCenter.default
            undoChangeObservers = [
                center.addObserver(
                    forName: .NSUndoManagerDidUndoChange,
                    object: undoManager,
                    queue: .main
                ) { [weak self] _ in
                    self?.synchronizeAfterUndoOrRedo()
                },
                center.addObserver(
                    forName: .NSUndoManagerDidRedoChange,
                    object: undoManager,
                    queue: .main
                ) { [weak self] _ in
                    self?.synchronizeAfterUndoOrRedo()
                },
            ]
        }

        private func removeUndoManagerObservers() {
            let center = NotificationCenter.default
            undoChangeObservers.forEach(center.removeObserver)
            undoChangeObservers.removeAll()
        }

        private func synchronizeAfterUndoOrRedo() {
            guard let textView else { return }
            if text != textView.string {
                revision += 1
                text = textView.string
            }
            onTypingSelectionChange?(snapshot(in: textView))
        }

        func configureTypingAssistance(
            suggestion: TypingAssistanceSuggestion?,
            onEditorChange:
                ((TypingAssistanceEditorSnapshot) -> TypingAssistanceTextEdit?)?,
            onSelectionChange:
                ((TypingAssistanceEditorSnapshot) -> Void)?,
            onDismissSuggestion: (() -> Void)?,
            onSuggestionApplicationFinished: ((Bool) -> Void)?,
            onAutomaticApplicationFinished:
                ((TypingAssistanceEditorSnapshot, Bool) -> Void)? = nil
        ) {
            typingAssistantSuggestion = suggestion
            self.onTypingEditorChange = onEditorChange
            self.onTypingSelectionChange = onSelectionChange
            self.onTypingDismissSuggestion = onDismissSuggestion
            self.onTypingSuggestionApplicationFinished =
                onSuggestionApplicationFinished
            self.onTypingAutomaticApplicationFinished =
                onAutomaticApplicationFinished
        }

        func applyTypingAssistantHighlight(
            theme: AppTheme,
            in textView: NSTextView
        ) {
            guard let layoutManager = textView.layoutManager else { return }
            if let previous = typingAssistantHighlightedRange {
                let currentTextRange = NSRange(
                    location: 0,
                    length: (textView.string as NSString).length
                )
                let removableRange = NSIntersectionRange(
                    previous,
                    currentTextRange
                )
                if removableRange.length > 0 {
                    layoutManager.removeTemporaryAttribute(
                        .underlineStyle,
                        forCharacterRange: removableRange
                    )
                    layoutManager.removeTemporaryAttribute(
                        .underlineColor,
                        forCharacterRange: removableRange
                    )
                }
                typingAssistantHighlightedRange = nil
            }

            guard let suggestion = typingAssistantSuggestion,
                  suggestion.requestKind != .completion,
                  suggestion.sourceDocumentID == documentID,
                  suggestion.sourceText == textView.string,
                  suggestion.replacementRange.location >= 0,
                  suggestion.replacementRange.length > 0,
                  NSMaxRange(suggestion.replacementRange)
                    <= (textView.string as NSString).length
            else {
                return
            }

            layoutManager.addTemporaryAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                forCharacterRange: suggestion.replacementRange
            )
            layoutManager.addTemporaryAttribute(
                .underlineColor,
                value: NSColor(hex: theme.accent),
                forCharacterRange: suggestion.replacementRange
            )
            typingAssistantHighlightedRange = suggestion.replacementRange
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

            publishCurrentScrollPosition()
            documentID = nextDocumentID
            lastPublishedScrollPosition = nil
            return true
        }

        func synchronizeExternalText(
            _ nextText: String,
            documentChanged: Bool
        ) {
            guard let textView else { return }
            let selectedRanges = documentChanged ? [] : textView.selectedRanges
            if textView.string != nextText {
                textView.string = nextText
            }
            if selectedRanges.isEmpty {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            } else {
                textView.selectedRanges = selectedRanges
            }
            revision += 1
            onTypingSelectionChange?(snapshot(in: textView))
        }

        func applySyncScrollTargetLine(_ line: Int?, in textView: NSTextView, scrollView: NSScrollView) {
            guard syncScrollEnabled, let line, line > 0, line != lastAppliedSyncScrollLine else { return }

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

        private func publishVisibleTopLineIfNeeded(in textView: NSTextView, scrollView: NSScrollView) {
            guard syncScrollEnabled, !isRestoringScrollPosition else { return }
            let line = visibleTopLine(in: textView, scrollView: scrollView)
            guard line > 0, line != lastPublishedTopLine else { return }
            lastPublishedTopLine = line
            onVisibleTopLineChange?(line)
        }

        private func publish(_ position: DocumentScrollPosition) {
            guard documentID != nil,
                  position.isMeaningfullyDifferent(from: lastPublishedScrollPosition)
            else {
                if syncScrollEnabled, let textView, let scrollView {
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

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            revision += 1
            text = textView.string
            let source = snapshot(in: textView)
            if isApplyingTypingAssistantSuggestion
                || textView.undoManager?.isUndoing == true
                || textView.undoManager?.isRedoing == true {
                onTypingSelectionChange?(source)
                return
            }
            guard let edit = onTypingEditorChange?(source) else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyAutomaticEdit(edit, source: source, in: textView)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            onTypingSelectionChange?(snapshot(in: textView))
        }

        func apply(_ request: MarkdownTextEditorCommandRequest) {
            guard request.serial != lastCommandSerial else { return }
            lastCommandSerial = request.serial
            _ = apply(request.command)
        }

        func apply(_ request: TypingAssistantEditorActionRequest) {
            guard request.serial != lastTypingAssistantActionSerial else {
                return
            }
            lastTypingAssistantActionSerial = request.serial
            _ = apply(request.action)
        }

        func apply(_ action: TypingAssistantEditorAction) -> Bool {
            switch action {
            case .accept:
                return applyTypingAssistantSuggestion()
            case .dismiss:
                guard typingAssistantSuggestion != nil else { return false }
                onTypingDismissSuggestion?()
                return true
            }
        }

        private func applyTypingAssistantSuggestion() -> Bool {
            guard let textView,
                  let suggestion = typingAssistantSuggestion
            else {
                return false
            }
            let source = snapshot(in: textView)
            let result = TypingAssistanceAcceptancePolicy.apply(
                suggestion,
                to: source
            )
            guard result.accepted else {
                onTypingSuggestionApplicationFinished?(false)
                return false
            }

            let sourceLength = (source.text as NSString).length
            let resultLength = (result.text as NSString).length
            let replacementLength = resultLength
                - sourceLength
                + suggestion.replacementRange.length
            guard replacementLength >= 0 else {
                onTypingSuggestionApplicationFinished?(false)
                return false
            }
            let replacementRange = NSRange(
                location: suggestion.replacementRange.location,
                length: replacementLength
            )
            let replacement = (result.text as NSString).substring(
                with: replacementRange
            )
            isApplyingTypingAssistantSuggestion = true
            defer { isApplyingTypingAssistantSuggestion = false }
            guard applyRegisteredTextEdit(
                range: suggestion.replacementRange,
                replacement: replacement,
                selectedRange: result.selectedRange,
                actionName: "Apply Writing Suggestion",
                in: textView
            ) else {
                onTypingSuggestionApplicationFinished?(false)
                return false
            }

            textView.scrollRangeToVisible(result.selectedRange)
            onTypingSuggestionApplicationFinished?(true)
            return true
        }

        private func applyAutomaticEdit(
            _ edit: TypingAssistanceTextEdit,
            source: TypingAssistanceEditorSnapshot,
            in textView: NSTextView
        ) {
            guard source == snapshot(in: textView),
                  edit.range.location >= 0,
                  edit.range.length >= 0,
                  NSMaxRange(edit.range) <= (textView.string as NSString).length
            else {
                onTypingAutomaticApplicationFinished?(source, false)
                return
            }
            let cursorDelta = (edit.replacementText as NSString).length
                - edit.range.length
            let nextCursor = max(
                edit.range.location + (edit.replacementText as NSString).length,
                source.cursorUTF16Offset + cursorDelta
            )
            let accepted = applyRegisteredTextEdit(
                range: edit.range,
                replacement: edit.replacementText,
                selectedRange: NSRange(location: nextCursor, length: 0),
                actionName: "Correct Typo",
                in: textView
            )
            onTypingAutomaticApplicationFinished?(source, accepted)
        }

        @discardableResult
        private func applyRegisteredTextEdit(
            range: NSRange,
            replacement: String,
            selectedRange: NSRange,
            actionName: String,
            in textView: NSTextView
        ) -> Bool {
            guard let textStorage = textView.textStorage,
                  range.location >= 0,
                  range.length >= 0,
                  NSMaxRange(range) <= (textView.string as NSString).length
            else {
                return false
            }

            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            guard textView.shouldChangeText(
                in: range,
                replacementString: replacement
            ) else {
                undoManager?.enableUndoRegistration()
                return false
            }

            let original = (textView.string as NSString).substring(with: range)
            let previousSelection = textView.selectedRange()
            let inverseRange = NSRange(
                location: range.location,
                length: (replacement as NSString).length
            )
            textView.breakUndoCoalescing()
            textStorage.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            textView.setSelectedRange(selectedRange)
            text = textView.string
            undoManager?.enableUndoRegistration()

            undoManager?.registerUndo(withTarget: self) { target in
                guard let currentTextView = target.textView else { return }
                _ = target.applyRegisteredTextEdit(
                    range: inverseRange,
                    replacement: original,
                    selectedRange: previousSelection,
                    actionName: actionName,
                    in: currentTextView
                )
            }
            undoManager?.setActionName(actionName)
            textView.breakUndoCoalescing()
            return true
        }

        private func snapshot(
            in textView: NSTextView
        ) -> TypingAssistanceEditorSnapshot {
            let selectedRange = textView.selectedRange()
            return TypingAssistanceEditorSnapshot(
                documentID: documentID ?? "",
                revision: revision,
                text: textView.string,
                cursorUTF16Offset: selectedRange.location
                    + selectedRange.length,
                selectionLength: selectedRange.length
            )
        }

        func apply(_ command: MarkdownTextEditorCommand) -> Bool {
            guard let textView, let textStorage = textView.textStorage else { return false }
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
            guard lastNavigatedLocation != location || textView.window?.firstResponder !== textView else { return }

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
            theme: AppTheme,
            in textView: NSTextView
        ) -> DocumentSearchResult {
            let request = DocumentSearchRequest(state)
            let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard state.isPresented, !query.isEmpty else {
                clearSearchHighlights(in: textView)
                lastSearchQuery = ""
                lastSearchedText = textView.string
                currentMatchIndex = 0
                lastNavigationSerial = request.navigationSerial
                return .init()
            }

            let text = textView.string
            let queryChanged = query != lastSearchQuery
            let textChanged = text != lastSearchedText
            let navigationChanged = request.navigationSerial != lastNavigationSerial
            let highlightTheme = SearchHighlightTheme(theme: theme)

            if queryChanged || textChanged {
                searchMatches = matchRanges(for: query, in: text)
            }

            let matches = searchMatches
            guard !matches.isEmpty else {
                clearSearchHighlights(in: textView)
                lastSearchQuery = query
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
            lastSearchedText = text
            lastNavigationSerial = request.navigationSerial

            return DocumentSearchResult(currentIndex: currentMatchIndex + 1, totalCount: matches.count)
        }

        private func matchRanges(for query: String, in text: String) -> [NSRange] {
            let nsText = text as NSString
            var ranges: [NSRange] = []
            var searchRange = NSRange(location: 0, length: nsText.length)

            while searchRange.length > 0 {
                let found = nsText.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                guard found.location != NSNotFound, found.length > 0 else { break }

                ranges.append(found)
                let nextLocation = found.location + found.length
                guard nextLocation < nsText.length else { break }
                searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
            }

            return ranges
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

private final class MarkdownNSTextView: NSTextView {
    var markdownShortcutsEnabled = false
    var wikilinkDocuments: [WorkspaceDocument] = []
    var commandHandler: ((MarkdownTextEditorCommand) -> Bool)?
    var typingAssistantCommandHandler:
        ((TypingAssistantEditorAction) -> Bool)?
    private var wikilinkSuggestionIndex = 0
    private var lastWikilinkPartial = ""
    var fontSmoothingEnabled = true {
        didSet {
            guard fontSmoothingEnabled != oldValue else { return }
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock])
        if event.keyCode == 48,
           modifiers.isEmpty,
           typingAssistantCommandHandler?(.accept) == true {
            return
        }
        if event.keyCode == 53,
           modifiers.isEmpty,
           typingAssistantCommandHandler?(.dismiss) == true {
            return
        }
        if event.keyCode == 48,
           modifiers.isEmpty,
           completeActiveWikilink() {
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

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else {
            super.draw(dirtyRect)
            return
        }

        let previousAntialiasing = context.shouldAntialias
        context.shouldAntialias = fontSmoothingEnabled
        super.draw(dirtyRect)
        context.shouldAntialias = previousAntialiasing
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
