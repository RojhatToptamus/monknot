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

struct MarkdownTextEditor: NSViewRepresentable {
    let documentID: String
    @Binding var text: String
    let theme: AppTheme
    let fontSize: CGFloat
    let zoomScale: Double
    let contentWidthPercent: Double
    let fontSmoothing: Bool
    let scrollPosition: DocumentScrollPosition?
    let textSelection: DocumentTextSelection?
    let syncScrollEnabled: Bool
    let syncScrollTargetLine: Int?
    @Binding var sourceLocation: MarkdownSourceLocation?
    @Binding var searchState: DocumentSearchState
    let onScrollPositionChange: (DocumentScrollPosition) -> Void
    let onVisibleTopLineChange: ((Int) -> Void)?
    let commandRequest: MarkdownTextEditorCommandRequest?
    let markdownShortcutsEnabled: Bool
    let wikilinkDocuments: [WorkspaceDocument]
    let onSelectionChange: ((MarkdownEditorSelectionSnapshot) -> Void)?
    let onOpenLink: ((MarkdownEditorLinkRequest) -> Void)?
    let onImagePasteRequest: ((MarkdownImagePasteRequest) -> Void)?

    init(
        documentID: String,
        text: Binding<String>,
        theme: AppTheme,
        fontSize: CGFloat,
        zoomScale: Double,
        contentWidthPercent: Double,
        fontSmoothing: Bool,
        scrollPosition: DocumentScrollPosition?,
        textSelection: DocumentTextSelection? = nil,
        sourceLocation: Binding<MarkdownSourceLocation?>,
        searchState: Binding<DocumentSearchState>,
        onScrollPositionChange: @escaping (DocumentScrollPosition) -> Void,
        syncScrollEnabled: Bool = false,
        syncScrollTargetLine: Int? = nil,
        onVisibleTopLineChange: ((Int) -> Void)? = nil,
        commandRequest: MarkdownTextEditorCommandRequest? = nil,
        markdownShortcutsEnabled: Bool = false,
        wikilinkDocuments: [WorkspaceDocument] = [],
        onSelectionChange: ((MarkdownEditorSelectionSnapshot) -> Void)? = nil,
        onOpenLink: ((MarkdownEditorLinkRequest) -> Void)? = nil,
        onImagePasteRequest: ((MarkdownImagePasteRequest) -> Void)? = nil
    ) {
        self.documentID = documentID
        self._text = text
        self.theme = theme
        self.fontSize = fontSize
        self.zoomScale = zoomScale
        self.contentWidthPercent = contentWidthPercent
        self.fontSmoothing = fontSmoothing
        self.scrollPosition = scrollPosition
        self.textSelection = textSelection
        self.syncScrollEnabled = syncScrollEnabled
        self.syncScrollTargetLine = syncScrollTargetLine
        self._sourceLocation = sourceLocation
        self._searchState = searchState
        self.onScrollPositionChange = onScrollPositionChange
        self.onVisibleTopLineChange = onVisibleTopLineChange
        self.commandRequest = commandRequest
        self.markdownShortcutsEnabled = markdownShortcutsEnabled
        self.wikilinkDocuments = wikilinkDocuments
        self.onSelectionChange = onSelectionChange
        self.onOpenLink = onOpenLink
        self.onImagePasteRequest = onImagePasteRequest
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
        textView.commandHandler = { [weak coordinator = context.coordinator] command in
            coordinator?.apply(command) ?? false
        }
        textView.workspaceLinkHandler = { [weak coordinator = context.coordinator] link in
            coordinator?.open(link) ?? false
        }
        textView.imagePasteHandler = { [weak coordinator = context.coordinator] image in
            coordinator?.requestImagePaste(image) ?? false
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
        context.coordinator.syncScrollEnabled = syncScrollEnabled
        let visibleOrigin = scrollView.contentView.bounds.origin

        if textView.string != text {
            let selectedRanges = didChangeDocument ? [] : textView.selectedRanges
            textView.string = text
            if selectedRanges.isEmpty {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            } else {
                textView.selectedRanges = selectedRanges
            }
            context.coordinator.externalTextDidChange()
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

        let searchApplication = context.coordinator.applySearch(searchState, theme: theme, in: textView)
        let currentSearchResult = DocumentSearchResult(
            currentIndex: searchState.currentIndex,
            totalCount: searchState.totalCount
        )
        if currentSearchResult != searchApplication.searchResult ||
            searchApplication.consumedReplacementSerial != nil {
            DispatchQueue.main.async {
                if let serial = searchApplication.consumedReplacementSerial {
                    self.searchState.consumeReplacement(serial: serial)
                }
                self.searchState.updateResult(searchApplication.searchResult)
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
        coordinator.textView?.imagePasteHandler = nil
        coordinator.textView = nil
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
        weak var textView: MarkdownNSTextView?
        var documentID: String?
        var onScrollPositionChange: (DocumentScrollPosition) -> Void = { _ in }
        var onVisibleTopLineChange: ((Int) -> Void)?
        var onSelectionChange: ((MarkdownEditorSelectionSnapshot) -> Void)?
        var onOpenLink: ((MarkdownEditorLinkRequest) -> Void)?
        var onImagePasteRequest: ((MarkdownImagePasteRequest) -> Void)?
        var syncScrollEnabled = false
        private var lastNavigatedLocation: MarkdownSourceLocation?
        private var searchMatches: [NSRange] = []
        private var highlightedRanges: [NSRange] = []
        private var lastSearchQuery = ""
        private var lastSearchedText = ""
        private var lastNavigationSerial = 0
        private var lastReplacementSerial = 0
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
        private var revision = 0
        private var lastPublishedSelection: MarkdownEditorSelectionSnapshot?
        private var shouldRestoreSelection = true

        init(text: Binding<String>) {
            self._text = text
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
            scrollView = nil
            onSelectionChange = nil
            onOpenLink = nil
            onImagePasteRequest = nil
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
            publishSelection()
            documentID = nextDocumentID
            revision += 1
            lastPublishedSelection = nil
            shouldRestoreSelection = true
            lastPublishedScrollPosition = nil
            lastSyntaxText = nil
            return true
        }

        func externalTextDidChange() {
            revision += 1
        }

        func restoreSelectionIfNeeded(
            _ selection: DocumentTextSelection?,
            in textView: NSTextView
        ) {
            guard shouldRestoreSelection else { return }
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
            guard !isRestoringScrollPosition else { return }
            let line = visibleTopLine(in: textView, scrollView: scrollView)
            guard line > 0, line != lastPublishedTopLine else { return }
            lastPublishedTopLine = line
            onVisibleTopLineChange?(line)
        }

        private func publish(_ position: DocumentScrollPosition) {
            guard documentID != nil,
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

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            revision += 1
            text = textView.string
            publishSelection()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard notification.object is NSTextView else { return }
            publishSelection()
        }

        func publishSelection() {
            guard let textView, let documentID, let onSelectionChange else { return }
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
            guard let textView,
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

        private func insertMarkdown(
            _ markdown: String,
            documentID: String,
            expectedRevision: Int,
            expectedText: String,
            expectedRange: NSRange
        ) -> Bool {
            guard !markdown.isEmpty,
                  self.documentID == documentID,
                  revision == expectedRevision,
                  let textView,
                  let textStorage = textView.textStorage,
                  textView.string == expectedText,
                  textView.selectedRange() == expectedRange,
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
        ) -> DocumentSearchApplicationResult {
            let consumedReplacementSerial = applyReplacementIfNeeded(
                state.replacementRequest,
                in: textView
            )
            let request = DocumentSearchRequest(state)
            let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard state.isPresented, !query.isEmpty else {
                clearSearchHighlights(in: textView)
                lastSearchQuery = ""
                lastSearchedText = textView.string
                currentMatchIndex = 0
                lastNavigationSerial = request.navigationSerial
                return DocumentSearchApplicationResult(
                    searchResult: .init(),
                    consumedReplacementSerial: consumedReplacementSerial
                )
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
                return DocumentSearchApplicationResult(
                    searchResult: .init(),
                    consumedReplacementSerial: consumedReplacementSerial
                )
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

            return DocumentSearchApplicationResult(
                searchResult: DocumentSearchResult(
                    currentIndex: currentMatchIndex + 1,
                    totalCount: matches.count
                ),
                consumedReplacementSerial: consumedReplacementSerial
            )
        }

        private func applyReplacementIfNeeded(
            _ request: DocumentReplacementRequest?,
            in textView: NSTextView
        ) -> Int? {
            guard let request, request.serial != lastReplacementSerial else { return nil }
            lastReplacementSerial = request.serial

            guard request.documentID == documentID,
                  textView.isEditable,
                  let textStorage = textView.textStorage
            else { return request.serial }

            let source = textView.string
            let matches = matchRanges(for: request.query, in: source)
            guard !matches.isEmpty else { return request.serial }

            switch request.action {
            case .current:
                replaceCurrentMatch(
                    in: matches,
                    replacement: request.replacement,
                    query: request.query,
                    requestedMatchIndex: request.matchIndex,
                    textStorage: textStorage,
                    textView: textView
                )
            case .all:
                replaceAllMatches(
                    matches,
                    replacement: request.replacement,
                    textStorage: textStorage,
                    textView: textView
                )
            }
            return request.serial
        }

        private func replaceCurrentMatch(
            in matches: [NSRange],
            replacement: String,
            query: String,
            requestedMatchIndex: Int,
            textStorage: NSTextStorage,
            textView: NSTextView
        ) {
            let selectedRange = textView.selectedRange()
            let selectedMatchIndex = matches.firstIndex { $0 == selectedRange }
            let targetIndex = selectedMatchIndex ?? min(requestedMatchIndex, matches.count - 1)
            let targetRange = matches[targetIndex]
            guard textView.shouldChangeText(in: targetRange, replacementString: replacement) else { return }

            textView.breakUndoCoalescing()
            textView.undoManager?.beginUndoGrouping()
            textStorage.replaceCharacters(in: targetRange, with: replacement)
            textView.didChangeText()

            let replacementEnd = targetRange.location + (replacement as NSString).length
            let updatedMatches = matchRanges(for: query, in: textView.string)
            if let nextIndex = updatedMatches.firstIndex(where: { $0.location >= replacementEnd }) {
                currentMatchIndex = nextIndex
                textView.setSelectedRange(updatedMatches[nextIndex])
                textView.scrollRangeToVisible(updatedMatches[nextIndex])
            } else if let firstMatch = updatedMatches.first {
                currentMatchIndex = 0
                textView.setSelectedRange(firstMatch)
                textView.scrollRangeToVisible(firstMatch)
            } else {
                currentMatchIndex = 0
                let caretRange = NSRange(
                    location: min(replacementEnd, (textView.string as NSString).length),
                    length: 0
                )
                textView.setSelectedRange(caretRange)
                textView.scrollRangeToVisible(caretRange)
            }

            textView.undoManager?.endUndoGrouping()
            textView.undoManager?.setActionName("Replace")
            textView.breakUndoCoalescing()
            textView.window?.makeFirstResponder(textView)
        }

        private func replaceAllMatches(
            _ matches: [NSRange],
            replacement: String,
            textStorage: NSTextStorage,
            textView: NSTextView
        ) {
            let replacementStrings = Array(repeating: replacement, count: matches.count)
            guard textView.shouldChangeText(
                inRanges: matches.map { NSValue(range: $0) },
                replacementStrings: replacementStrings
            ) else { return }

            let selectedRange = textView.selectedRange()
            let visibleOrigin = scrollView?.contentView.bounds.origin
            let replacementLength = (replacement as NSString).length

            textView.breakUndoCoalescing()
            textView.undoManager?.beginUndoGrouping()
            textStorage.beginEditing()
            for range in matches.reversed() {
                textStorage.replaceCharacters(in: range, with: replacement)
            }
            textStorage.endEditing()
            textView.didChangeText()

            let nextSelection = transformedSelection(
                selectedRange,
                replacing: matches,
                withLength: replacementLength,
                in: textView.string
            )
            textView.setSelectedRange(nextSelection)
            if let visibleOrigin, let scrollView {
                restoreScrollPosition(visibleOrigin, in: scrollView, shouldPublish: false)
            }
            currentMatchIndex = 0

            textView.undoManager?.endUndoGrouping()
            textView.undoManager?.setActionName("Replace All")
            textView.breakUndoCoalescing()
            textView.window?.makeFirstResponder(textView)
        }

        private func transformedSelection(
            _ selection: NSRange,
            replacing matches: [NSRange],
            withLength replacementLength: Int,
            in updatedText: String
        ) -> NSRange {
            if selection.length == 0 {
                let caret = transformedCaret(
                    selection.location,
                    replacing: matches,
                    withLength: replacementLength
                )
                return Self.boundedRange(NSRange(location: caret, length: 0), in: updatedText)
            }

            let start = transformedBoundary(
                selection.location,
                replacing: matches,
                withLength: replacementLength,
                prefersReplacementEnd: false
            )
            let end = transformedBoundary(
                NSMaxRange(selection),
                replacing: matches,
                withLength: replacementLength,
                prefersReplacementEnd: true
            )
            return Self.boundedRange(
                NSRange(location: start, length: max(0, end - start)),
                in: updatedText
            )
        }

        private func transformedCaret(
            _ offset: Int,
            replacing matches: [NSRange],
            withLength replacementLength: Int
        ) -> Int {
            var delta = 0
            for match in matches {
                if offset < match.location { break }
                if offset <= NSMaxRange(match) {
                    return match.location + delta + replacementLength
                }
                delta += replacementLength - match.length
            }
            return offset + delta
        }

        private func transformedBoundary(
            _ offset: Int,
            replacing matches: [NSRange],
            withLength replacementLength: Int,
            prefersReplacementEnd: Bool
        ) -> Int {
            var delta = 0
            for match in matches {
                if offset <= match.location { break }
                if offset < NSMaxRange(match) {
                    return match.location + delta + (prefersReplacementEnd ? replacementLength : 0)
                }
                delta += replacementLength - match.length
            }
            return offset + delta
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

final class MarkdownNSTextView: NSTextView {
    var markdownShortcutsEnabled = false
    var wikilinkDocuments: [WorkspaceDocument] = []
    var commandHandler: ((MarkdownTextEditorCommand) -> Bool)?
    var workspaceLinkHandler: ((MarkdownWorkspaceLink) -> Bool)?
    var imagePasteHandler: ((NSImage) -> Bool)?
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshContentWidthLayout()
    }

    override func mouseDown(with event: NSEvent) {
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

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        guard selectedRange().length > 0,
              menu.items.contains(where: { $0.action == #selector(copyRenderedMarkdown(_:)) }) == false
        else { return menu }

        menu.addItem(.separator())
        let item = NSMenuItem(
            title: "Copy Rendered",
            action: #selector(copyRenderedMarkdown(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
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
        if event.keyCode == 48,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock]).isEmpty,
           completeActiveWikilink() {
            return
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

        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        textStorage.replaceCharacters(in: plan.replacementRange, with: plan.replacementText)
        didChangeText()
        setSelectedRange(plan.selectedRange)
        scrollRangeToVisible(plan.selectedRange)
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(listActionName(command))
        breakUndoCoalescing()
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
