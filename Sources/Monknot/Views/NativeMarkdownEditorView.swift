import MonknotCore
import SwiftUI

struct NativeMarkdownEditorView: View {
    let documentID: String
    @Binding var text: String
    let theme: AppTheme
    let fontSize: CGFloat
    let zoomScale: Double
    let contentWidthPercent: Double
    let fontSmoothing: Bool
    let textCheckingOptions: EditorTextCheckingOptions
    let flowSourceMode: FlowSourceMode?
    let scrollPosition: DocumentScrollPosition?
    let textSelection: DocumentTextSelection?
    let syncScrollEnabled: Bool
    let syncScrollTargetLine: Int?
    let openingTopLine: Int?
    @Binding var sourceLocation: MarkdownSourceLocation?
    @Binding var searchState: DocumentSearchState
    let searchOptions: MonknotSearchOptions
    let wikilinkDocuments: [WorkspaceDocument]
    let onScrollPositionChange: (DocumentScrollPosition) -> Void
    let onVisibleTopLineChange: ((Int) -> Void)?
    let onSelectionChange: ((MarkdownEditorSelectionSnapshot) -> Void)?
    let onOpenLink: ((MarkdownEditorLinkRequest) -> Void)?
    let onInspectLinks: (() -> Void)?
    let onImagePasteRequest: ((MarkdownImagePasteRequest) -> Void)?
    let onFileDropRequest: ((MarkdownFileDropRequest) -> Void)?
    let onWritingToolsTextCommit: ((String, String) -> Void)?
    let onWritingToolsStateChange: ((String, Bool) -> Bool)?
    @Binding var writingToolsRequested: Bool

    init(
        documentID: String,
        text: Binding<String>,
        theme: AppTheme,
        fontSize: CGFloat,
        zoomScale: Double,
        contentWidthPercent: Double,
        fontSmoothing: Bool,
        textCheckingOptions: EditorTextCheckingOptions = .defaultValue,
        flowSourceMode: FlowSourceMode? = .markdown,
        scrollPosition: DocumentScrollPosition?,
        textSelection: DocumentTextSelection? = nil,
        syncScrollEnabled: Bool,
        syncScrollTargetLine: Int?,
        openingTopLine: Int? = nil,
        sourceLocation: Binding<MarkdownSourceLocation?>,
        searchState: Binding<DocumentSearchState>,
        searchOptions: MonknotSearchOptions = MonknotSearchOptions(),
        wikilinkDocuments: [WorkspaceDocument],
        onSelectionChange: ((MarkdownEditorSelectionSnapshot) -> Void)? = nil,
        onOpenLink: ((MarkdownEditorLinkRequest) -> Void)? = nil,
        onInspectLinks: (() -> Void)? = nil,
        onImagePasteRequest: ((MarkdownImagePasteRequest) -> Void)? = nil,
        onFileDropRequest: ((MarkdownFileDropRequest) -> Void)? = nil,
        onWritingToolsTextCommit: ((String, String) -> Void)? = nil,
        onWritingToolsStateChange: ((String, Bool) -> Bool)? = nil,
        writingToolsRequested: Binding<Bool> = .constant(false),
        onScrollPositionChange: @escaping (DocumentScrollPosition) -> Void,
        onVisibleTopLineChange: ((Int) -> Void)?
    ) {
        self.documentID = documentID
        self._text = text
        self.theme = theme
        self.fontSize = fontSize
        self.zoomScale = zoomScale
        self.contentWidthPercent = contentWidthPercent
        self.fontSmoothing = fontSmoothing
        self.textCheckingOptions = textCheckingOptions
        self.flowSourceMode = flowSourceMode
        self.scrollPosition = scrollPosition
        self.textSelection = textSelection
        self.syncScrollEnabled = syncScrollEnabled
        self.syncScrollTargetLine = syncScrollTargetLine
        self.openingTopLine = openingTopLine
        self._sourceLocation = sourceLocation
        self._searchState = searchState
        self.searchOptions = searchOptions
        self.wikilinkDocuments = wikilinkDocuments
        self.onSelectionChange = onSelectionChange
        self.onOpenLink = onOpenLink
        self.onInspectLinks = onInspectLinks
        self.onImagePasteRequest = onImagePasteRequest
        self.onFileDropRequest = onFileDropRequest
        self.onWritingToolsTextCommit = onWritingToolsTextCommit
        self.onWritingToolsStateChange = onWritingToolsStateChange
        self._writingToolsRequested = writingToolsRequested
        self.onScrollPositionChange = onScrollPositionChange
        self.onVisibleTopLineChange = onVisibleTopLineChange
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                MarkdownTextEditor(
                    documentID: documentID,
                    text: $text,
                    theme: theme,
                    fontSize: fontSize,
                    zoomScale: zoomScale,
                    contentWidthPercent: contentWidthPercent,
                    fontSmoothing: fontSmoothing,
                    textCheckingOptions: textCheckingOptions,
                    scrollPosition: scrollPosition,
                    textSelection: textSelection,
                    sourceLocation: $sourceLocation,
                    searchState: $searchState,
                    searchOptions: searchOptions,
                    onScrollPositionChange: onScrollPositionChange,
                    syncScrollEnabled: syncScrollEnabled,
                    syncScrollTargetLine: syncScrollTargetLine,
                    openingTopLine: openingTopLine,
                    onVisibleTopLineChange: onVisibleTopLineChange,
                    markdownShortcutsEnabled: true,
                    flowSourceMode: flowSourceMode,
                    wikilinkDocuments: wikilinkDocuments,
                    onSelectionChange: onSelectionChange,
                    onOpenLink: onOpenLink,
                    onInspectLinks: onInspectLinks,
                    onImagePasteRequest: onImagePasteRequest,
                    onFileDropRequest: onFileDropRequest,
                    onWritingToolsTextCommit: onWritingToolsTextCommit,
                    onWritingToolsStateChange: onWritingToolsStateChange,
                    writingToolsRequested: $writingToolsRequested
                )

                if text.isEmpty {
                    Text("Start writing")
                        .font(
                            .system(
                                size: max(
                                    fontSize,
                                    ContentWidthPreference.editorPlaceholderMinimumFontSize(
                                        zoomScale: zoomScale
                                    )
                                ),
                                weight: .regular
                            )
                        )
                        // A placeholder is `ink4`, as Preview's is (design.md §1.2).
                        .foregroundStyle(theme.disabledForegroundColor)
                        .padding(
                            .leading,
                            ContentWidthPreference.editorPlaceholderLeadingInset(
                                viewportWidth: proxy.size.width,
                                contentWidthPercent: contentWidthPercent,
                                zoomScale: zoomScale,
                                fontSize: fontSize
                            )
                        )
                        .padding(
                            .top,
                            ContentWidthPreference.editorPlaceholderTopInset(fontSize: fontSize, zoomScale: zoomScale)
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .background(theme.surfaceColor)
    }
}

/// The document's word count in the bottom-trailing corner of the editor, in Source and Preview
/// alike: 12 `ink3` with tabular digits on a `surface` capsule, so text scrolling under it stays
/// legible. Anchored at its trailing edge, a changing count never moves the corner it sits in. The
/// full count (lines and words) is its help text and accessibility label.
struct MarkdownWordCountLabel: View {
    let theme: AppTheme
    let zoomScale: Double
    let statistics: MarkdownTextStatistics?

    var body: some View {
        Text(statistics.map { Self.wordCountLabel($0.wordCount) } ?? "")
            .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
            .monospacedDigit()
            .foregroundStyle(theme.tertiaryForegroundColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, MonknotMetrics.interfaceDensity(8, theme: theme, zoomScale: zoomScale))
            .padding(.vertical, MonknotMetrics.interfaceDensity(4, theme: theme, zoomScale: zoomScale))
            .background(theme.surfaceColor.opacity(0.92), in: Capsule())
            .opacity(statistics == nil ? 0 : 1)
            .help(statistics.map(Self.statisticsDescription) ?? "")
            .accessibilityLabel(statistics.map(Self.statisticsDescription) ?? "")
            .accessibilityHidden(statistics == nil)
            .allowsHitTesting(statistics != nil)
    }

    static func wordCountLabel(_ wordCount: Int) -> String {
        wordCount == 1 ? "1 word" : "\(wordCount.formatted()) words"
    }

    static func statisticsDescription(_ statistics: MarkdownTextStatistics) -> String {
        let lines = statistics.lineCount == 1 ? "1 line" : "\(statistics.lineCount.formatted()) lines"
        return "\(lines), \(wordCountLabel(statistics.wordCount))"
    }
}
