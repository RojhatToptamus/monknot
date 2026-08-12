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
    let scrollPosition: DocumentScrollPosition?
    let textSelection: DocumentTextSelection?
    let syncScrollEnabled: Bool
    let syncScrollTargetLine: Int?
    @Binding var sourceLocation: MarkdownSourceLocation?
    @Binding var searchState: DocumentSearchState
    let commandRequest: MarkdownTextEditorCommandRequest?
    let wikilinkDocuments: [WorkspaceDocument]
    let onScrollPositionChange: (DocumentScrollPosition) -> Void
    let onVisibleTopLineChange: ((Int) -> Void)?
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
        syncScrollEnabled: Bool,
        syncScrollTargetLine: Int?,
        sourceLocation: Binding<MarkdownSourceLocation?>,
        searchState: Binding<DocumentSearchState>,
        commandRequest: MarkdownTextEditorCommandRequest?,
        wikilinkDocuments: [WorkspaceDocument],
        onSelectionChange: ((MarkdownEditorSelectionSnapshot) -> Void)? = nil,
        onOpenLink: ((MarkdownEditorLinkRequest) -> Void)? = nil,
        onImagePasteRequest: ((MarkdownImagePasteRequest) -> Void)? = nil,
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
        self.scrollPosition = scrollPosition
        self.textSelection = textSelection
        self.syncScrollEnabled = syncScrollEnabled
        self.syncScrollTargetLine = syncScrollTargetLine
        self._sourceLocation = sourceLocation
        self._searchState = searchState
        self.commandRequest = commandRequest
        self.wikilinkDocuments = wikilinkDocuments
        self.onSelectionChange = onSelectionChange
        self.onOpenLink = onOpenLink
        self.onImagePasteRequest = onImagePasteRequest
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
                    scrollPosition: scrollPosition,
                    textSelection: textSelection,
                    sourceLocation: $sourceLocation,
                    searchState: $searchState,
                    onScrollPositionChange: onScrollPositionChange,
                    syncScrollEnabled: syncScrollEnabled,
                    syncScrollTargetLine: syncScrollTargetLine,
                    onVisibleTopLineChange: onVisibleTopLineChange,
                    commandRequest: commandRequest,
                    markdownShortcutsEnabled: true,
                    wikilinkDocuments: wikilinkDocuments,
                    onSelectionChange: onSelectionChange,
                    onOpenLink: onOpenLink,
                    onImagePasteRequest: onImagePasteRequest
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

struct MarkdownSourceToolbar: View {
    let theme: AppTheme
    let zoomScale: Double
    let text: String
    let sendCommand: (MarkdownTextEditorCommand) -> Void

    static let regularActionGroups = [
        [
            MarkdownToolbarActionDescriptor(systemImage: "bold", label: "Bold", command: .bold),
            MarkdownToolbarActionDescriptor(systemImage: "italic", label: "Italic", command: .italic),
            MarkdownToolbarActionDescriptor(systemImage: "quote.opening", label: "Quote", command: .quote),
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

    private func glyphScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceGlyph(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                regularToolbar
                compactToolbar
                minimalToolbar
            }

            Spacer(minLength: 0)

            Text("\(lineCount)/\(wordCount)")
                .font(.system(size: textScaled(12), weight: .regular, design: .monospaced))
                .foregroundStyle(theme.tertiaryForegroundColor)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel("\(lineCount) lines, \(wordCount) words")
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
        headingMenu(width: scaled(92))
    }

    private var compactHeadingMenu: some View {
        headingMenu(width: scaled(104))
    }

    private func headingMenu(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale))

        return Menu {
            blockStyleCommands
        } label: {
            HStack(spacing: scaled(7)) {
                Text("Paragraph")
                    .font(.system(size: textScaled(12), weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.system(size: glyphScaled(9), weight: .semibold))
                    .foregroundStyle(theme.mutedForegroundColor)
            }
            .foregroundStyle(theme.foregroundColor)
            .padding(.horizontal, scaled(10))
            .frame(
                width: width,
                height: MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoomScale)
            )
            .background(shape.fill(theme.controlTrackFillColor))
            .contentShape(shape)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Block Style")
        .accessibilityLabel("Block Style")
    }

    private var blockStyleIconMenu: some View {
        Menu {
            blockStyleCommands
        } label: {
            toolbarMenuLabel(systemImage: "textformat.size")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
        Menu {
            listCommands
        } label: {
            toolbarMenuLabel(systemImage: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("List Formatting")
        .accessibilityLabel("List Formatting")
    }

    private func overflowMenu(includesLink: Bool, includesLists: Bool) -> some View {
        Menu {
            Button("Quote", systemImage: "quote.opening") { sendCommand(.quote) }
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
        } label: {
            toolbarMenuLabel(systemImage: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More formatting actions")
        .accessibilityLabel("More formatting actions")
    }

    @ViewBuilder
    private var listCommands: some View {
        Button("Bullet List", systemImage: "list.bullet") { sendCommand(.bulletList) }
        Button("Numbered List", systemImage: "list.number") { sendCommand(.numberedList) }
        Button("Task List", systemImage: "checklist") { sendCommand(.taskList) }
    }

    private func toolbarMenuLabel(systemImage: String) -> some View {
        let dimension = MonknotMetrics.interfaceControl(30, theme: theme, zoomScale: zoomScale)
        let shape = RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale))

        return Image(systemName: systemImage)
            .font(.system(size: glyphScaled(18), weight: .regular))
            .foregroundStyle(theme.mutedForegroundColor)
            .frame(width: dimension, height: dimension)
            .contentShape(shape)
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
            size: .editorToolbar,
            action: { sendCommand(command) }
        )
    }

    private var lineCount: Int {
        max(1, text.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        })
    }

    private var wordCount: Int {
        text.split { $0.isWhitespace || $0.isPunctuation }.count
    }
}
