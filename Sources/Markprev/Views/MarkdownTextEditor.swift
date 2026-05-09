import AppKit
import MarkprevCore
import SwiftUI

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let theme: AppTheme
    let fontSize: CGFloat
    let fontSmoothing: Bool
    @Binding var sourceLocation: MarkdownSourceLocation?
    @Binding var searchState: DocumentSearchState

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

        let textView = MarkdownNSTextView()
        textView.fontSmoothingEnabled = fontSmoothing
        textView.delegate = context.coordinator
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
        textView.font = font(for: theme, size: fontSize)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        applyTheme(theme, to: textView, in: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let visibleOrigin = scrollView.contentView.bounds.origin

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }

        textView.font = font(for: theme, size: fontSize)
        if let textView = textView as? MarkdownNSTextView {
            textView.fontSmoothingEnabled = fontSmoothing
        }
        applyTheme(theme, to: textView, in: scrollView)
        scrollView.contentView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        if let sourceLocation {
            context.coordinator.navigate(to: sourceLocation, in: textView)
            DispatchQueue.main.async {
                self.sourceLocation = nil
            }
        }

        let searchResult = context.coordinator.applySearch(searchState, theme: theme, in: textView)
        if DocumentSearchResult(currentIndex: searchState.currentIndex, totalCount: searchState.totalCount) != searchResult {
            DispatchQueue.main.async {
                self.searchState.updateResult(searchResult)
            }
        }
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
        weak var textView: NSTextView?
        private var lastNavigatedLocation: MarkdownSourceLocation?
        private var searchMatches: [NSRange] = []
        private var highlightedRanges: [NSRange] = []
        private var lastSearchQuery = ""
        private var lastSearchedText = ""
        private var lastNavigationSerial = 0
        private var currentMatchIndex = 0
        private var lastHighlightTheme: SearchHighlightTheme?

        init(text: Binding<String>) {
            self._text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
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

private final class MarkdownNSTextView: NSTextView {
    var fontSmoothingEnabled = true {
        didSet {
            guard fontSmoothingEnabled != oldValue else { return }
            needsDisplay = true
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
}
