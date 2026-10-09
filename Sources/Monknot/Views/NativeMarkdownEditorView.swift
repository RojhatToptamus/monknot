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
    let commandRequest: MarkdownTextEditorCommandRequest?
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
        commandRequest: MarkdownTextEditorCommandRequest?,
        wikilinkDocuments: [WorkspaceDocument],
        onSelectionChange: ((MarkdownEditorSelectionSnapshot) -> Void)? = nil,
        onOpenLink: ((MarkdownEditorLinkRequest) -> Void)? = nil,
        onInspectLinks: (() -> Void)? = nil,
        onImagePasteRequest: ((MarkdownImagePasteRequest) -> Void)? = nil,
        onFileDropRequest: ((MarkdownFileDropRequest) -> Void)? = nil,
        onWritingToolsTextCommit: ((String, String) -> Void)? = nil,
        onWritingToolsStateChange: ((String, Bool) -> Bool)? = nil,
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
        self.commandRequest = commandRequest
        self.wikilinkDocuments = wikilinkDocuments
        self.onSelectionChange = onSelectionChange
        self.onOpenLink = onOpenLink
        self.onInspectLinks = onInspectLinks
        self.onImagePasteRequest = onImagePasteRequest
        self.onFileDropRequest = onFileDropRequest
        self.onWritingToolsTextCommit = onWritingToolsTextCommit
        self.onWritingToolsStateChange = onWritingToolsStateChange
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
                    commandRequest: commandRequest,
                    markdownShortcutsEnabled: true,
                    flowSourceMode: flowSourceMode,
                    wikilinkDocuments: wikilinkDocuments,
                    onSelectionChange: onSelectionChange,
                    onOpenLink: onOpenLink,
                    onInspectLinks: onInspectLinks,
                    onImagePasteRequest: onImagePasteRequest,
                    onFileDropRequest: onFileDropRequest,
                    onWritingToolsTextCommit: onWritingToolsTextCommit,
                    onWritingToolsStateChange: onWritingToolsStateChange
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
                        .foregroundStyle(theme.mutedForegroundColor.opacity(0.52))
                        .padding(
                            .leading,
                            ContentWidthPreference.editorPlaceholderLeadingInset(
                                viewportWidth: proxy.size.width,
                                contentWidthPercent: contentWidthPercent,
                                zoomScale: zoomScale
                            )
                        )
                        .padding(
                            .top,
                            ContentWidthPreference.editorPlaceholderTopInset(zoomScale: zoomScale)
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .background(theme.surfaceColor)
    }
}

struct MarkdownToolbarActionDescriptor: Identifiable {
    let systemImage: String
    let label: String
    let command: MarkdownTextEditorCommand

    var id: String { label }
}

/// The toolbar redraws when its theme, zoom or statistics change, not on every keystroke in the
/// pane around it. `sendCommand` forwards to the pane and is not compared.
extension MarkdownSourceToolbar: Equatable {
    nonisolated static func == (lhs: MarkdownSourceToolbar, rhs: MarkdownSourceToolbar) -> Bool {
        MainActor.assumeIsolated {
            lhs.zoomScale == rhs.zoomScale &&
                lhs.statistics == rhs.statistics &&
                lhs.theme == rhs.theme
        }
    }
}

/// A menu in the Markdown toolbar, with the same box and states as the icon buttons beside it: no fill
/// at rest, the shared hover fill, the label one step up the ink ladder while hovered (design.md §1.4,
/// §5.1) and the standard focus ring. SwiftUI draws the label: a `.borderlessButton` menu hands it to an
/// AppKit pop-up button, which keeps only its text or image and drops the frame, fill and hover.
private struct MarkdownToolbarMenu<Content: View, Label: View>: View {
    let theme: AppTheme
    let zoomScale: Double
    /// The label's width; `nil` makes the menu square, like an icon button.
    var width: CGFloat?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: (_ isHovered: Bool) -> Label
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let size = MarkdownSourceToolbar.controlSize
        let dimension = size.dimension(theme: theme, zoomScale: zoomScale)
        let cornerRadius = size.cornerRadius(theme: theme, zoomScale: zoomScale)
        let shape = RoundedRectangle(cornerRadius: cornerRadius)

        Menu {
            content()
        } label: {
            label(isHovered)
                .frame(width: width ?? dimension, height: dimension)
                .background {
                    if isHovered {
                        shape.fill(theme.hoverFillColor)
                    }
                }
                .contentShape(shape)
                .monknotFocusRing(isVisible: isFocused, cornerRadius: cornerRadius, theme: theme)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .focusable(NSApp.isFullKeyboardAccessEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .fixedSize()
    }
}

struct MarkdownSourceToolbar: View {
    let theme: AppTheme
    let zoomScale: Double
    let statistics: MarkdownTextStatistics?
    let sendCommand: (MarkdownTextEditorCommand) -> Void

    static let controlSize = MonknotIconButton.IconButtonSize.editorToolbar
    static let expandedHeadingWidthBase: CGFloat = 100
    static let compactHeadingWidthBase: CGFloat = 104
    static let headingFontSizeBase: CGFloat = 13
    static let headingChevronFontSizeBase: CGFloat = 10
    static let headingChevronBaselineOffsetBase: CGFloat = 3.2

    static let regularActionGroups = [
        [
            MarkdownToolbarActionDescriptor(systemImage: "bold", label: "Bold", command: .bold),
            MarkdownToolbarActionDescriptor(systemImage: "italic", label: "Italic", command: .italic),
            MarkdownToolbarActionDescriptor(systemImage: "text.quote", label: "Quote", command: .quote),
            MarkdownToolbarActionDescriptor(systemImage: "curlybraces", label: "Inline Code", command: .code),
            MarkdownToolbarActionDescriptor(systemImage: "link", label: "Link", command: .link),
        ],
        [
            MarkdownToolbarActionDescriptor(systemImage: "list.bullet", label: "Bullet List", command: .bulletList),
            MarkdownToolbarActionDescriptor(systemImage: "list.number", label: "Numbered List", command: .numberedList),
            MarkdownToolbarActionDescriptor(systemImage: "checklist", label: "Task List", command: .taskList),
        ],
        [
            MarkdownToolbarActionDescriptor(systemImage: "photo", label: "Image", command: .image),
            MarkdownToolbarActionDescriptor(systemImage: "minus", label: "Horizontal Rule", command: .horizontalRule),
        ],
    ]

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                regularToolbar
                compactToolbar
                minimalToolbar
            }

            Spacer(minLength: 0)

            if let statistics {
                Text(Self.wordCountLabel(statistics.wordCount))
                    .font(.system(size: textScaled(12), weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .lineLimit(1)
                    .fixedSize()
                    .help(Self.statisticsDescription(statistics))
                    .accessibilityLabel(Self.statisticsDescription(statistics))
            }
        }
        .monknotChromeSubrowLayout(theme: theme, zoomScale: zoomScale)
    }

    private var regularToolbar: some View {
        HStack(spacing: scaled(6)) {
            expandedHeadingMenu

            ForEach(Self.regularActionGroups.indices, id: \.self) { groupIndex in
                divider
                ForEach(Self.regularActionGroups[groupIndex]) { action in
                    toolbarButton(action.systemImage, action.label, action.command)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactToolbar: some View {
        HStack(spacing: scaled(6)) {
            compactHeadingMenu
            divider
            toolbarButton("bold", "Bold", .bold)
            toolbarButton("italic", "Italic", .italic)
            toolbarButton("link", "Link", .link)
            listsMenu
            overflowMenu(includesLink: false, includesLists: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var minimalToolbar: some View {
        HStack(spacing: scaled(6)) {
            blockStyleIconMenu
            toolbarButton("bold", "Bold", .bold)
            toolbarButton("italic", "Italic", .italic)
            overflowMenu(includesLink: true, includesLists: true)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var expandedHeadingMenu: some View {
        headingMenu(width: scaled(Self.expandedHeadingWidthBase))
    }

    private var compactHeadingMenu: some View {
        headingMenu(width: scaled(Self.compactHeadingWidthBase))
    }

    private func headingMenu(width: CGFloat) -> some View {
        MarkdownToolbarMenu(theme: theme, zoomScale: zoomScale, width: width) {
            blockStyleCommands
        } label: { isHovered in
            headingMenuLabel(isHovered: isHovered)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, scaled(10))
        }
        .help("Block Style")
        .accessibilityLabel("Block Style")
    }

    private func headingMenuLabel(isHovered: Bool) -> Text {
        // One composed Text keeps the title and indicator on one baseline. The arrowhead's SF Pro ink
        // sits 3.2pt below the title's optical center.
        Text("Paragraph")
            .font(.system(size: textScaled(Self.headingFontSizeBase), weight: .regular))
            .foregroundColor(isHovered ? theme.foregroundColor : theme.mutedForegroundColor)
        + Text(verbatim: "\u{2002}")
            .font(.system(size: textScaled(Self.headingFontSizeBase), weight: .regular))
        + Text(verbatim: "⌄")
            .font(.system(size: textScaled(Self.headingChevronFontSizeBase), weight: .regular))
            .baselineOffset(textScaled(Self.headingChevronBaselineOffsetBase))
            .foregroundColor(isHovered ? theme.foregroundColor : theme.tertiaryForegroundColor)
    }

    private var blockStyleIconMenu: some View {
        iconMenu(systemImage: "textformat.size") {
            blockStyleCommands
        }
        .help("Block Style")
        .accessibilityLabel("Block Style")
    }

    @ViewBuilder
    private var blockStyleCommands: some View {
        Button("Paragraph") { sendCommand(.paragraph) }
        Divider()
        Button("Heading 1") { sendCommand(.heading(level: 1)) }
        Button("Heading 2") { sendCommand(.heading(level: 2)) }
        Button("Heading 3") { sendCommand(.heading(level: 3)) }
    }

    private var listsMenu: some View {
        iconMenu(systemImage: "list.bullet") {
            listCommands
        }
        .help("List Formatting")
        .accessibilityLabel("List Formatting")
    }

    private func overflowMenu(includesLink: Bool, includesLists: Bool) -> some View {
        iconMenu(systemImage: "ellipsis") {
            Button("Quote", systemImage: "text.quote") { sendCommand(.quote) }
            Button("Inline Code", systemImage: "curlybraces") { sendCommand(.code) }
            if includesLink {
                Button("Link", systemImage: "link") { sendCommand(.link) }
            }

            Divider()

            if includesLists {
                Menu("Lists", systemImage: "list.bullet") {
                    listCommands
                }
            }

            Menu("Insert", systemImage: "plus") {
                Button("Image", systemImage: "photo") { sendCommand(.image) }
                Button("Horizontal Rule", systemImage: "minus") { sendCommand(.horizontalRule) }
            }
        }
        .help("More formatting actions")
        .accessibilityLabel("More formatting actions")
    }

    @ViewBuilder
    private var listCommands: some View {
        Button("Bullet List", systemImage: "list.bullet") { sendCommand(.bulletList) }
        Button("Numbered List", systemImage: "list.number") { sendCommand(.numberedList) }
        Button("Task List", systemImage: "checklist") { sendCommand(.taskList) }
    }

    private func iconMenu<Content: View>(
        systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        MarkdownToolbarMenu(theme: theme, zoomScale: zoomScale, content: content) { isHovered in
            MonknotSystemGlyph(
                systemImage: systemImage,
                nominalPointSizeBase: Self.controlSize.iconPointSizeBase,
                theme: theme,
                zoomScale: zoomScale
            )
            .foregroundStyle(isHovered ? theme.foregroundColor : theme.mutedForegroundColor)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.borderColor)
            .frame(
                width: 1,
                height: MonknotMetrics.interfaceControl(20, theme: theme, zoomScale: zoomScale)
            )
            .padding(.horizontal, scaled(2))
    }

    private func toolbarButton(
        _ systemImage: String,
        _ label: String,
        _ command: MarkdownTextEditorCommand
    ) -> some View {
        MonknotIconButton(
            systemImage: systemImage,
            label: label,
            theme: theme,
            zoomScale: zoomScale,
            size: Self.controlSize,
            action: { sendCommand(command) }
        )
    }

    static func wordCountLabel(_ wordCount: Int) -> String {
        wordCount == 1 ? "1 word" : "\(wordCount.formatted()) words"
    }

    static func statisticsDescription(_ statistics: MarkdownTextStatistics) -> String {
        let lines = statistics.lineCount == 1 ? "1 line" : "\(statistics.lineCount.formatted()) lines"
        return "\(lines), \(wordCountLabel(statistics.wordCount))"
    }
}
