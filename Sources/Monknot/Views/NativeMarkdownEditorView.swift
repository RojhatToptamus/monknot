import MonknotCore
import SwiftUI

struct NativeMarkdownEditorView: View {
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
    let commandRequest: MarkdownTextEditorCommandRequest?
    let wikilinkDocuments: [WorkspaceDocument]
    let onScrollPositionChange: (DocumentScrollPosition) -> Void
    let onVisibleTopLineChange: ((Int) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            MarkdownTextEditor(
                documentID: documentID,
                text: $text,
                theme: theme,
                fontSize: fontSize,
                fontSmoothing: fontSmoothing,
                scrollPosition: scrollPosition,
                sourceLocation: $sourceLocation,
                searchState: $searchState,
                onScrollPositionChange: onScrollPositionChange,
                syncScrollEnabled: syncScrollEnabled,
                syncScrollTargetLine: syncScrollTargetLine,
                onVisibleTopLineChange: onVisibleTopLineChange,
                commandRequest: commandRequest,
                markdownShortcutsEnabled: true,
                wikilinkDocuments: wikilinkDocuments
            )

            if text.isEmpty {
                Text("Start writing")
                    .font(.system(size: max(fontSize, 13), weight: .regular))
                    .foregroundStyle(theme.mutedForegroundColor.opacity(0.52))
                    .padding(.leading, 28)
                    .padding(.top, 26)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(theme.surfaceColor)
    }
}

struct MarkdownSourceToolbar: View {
    let theme: AppTheme
    let zoomScale: Double
    let sendCommand: (MarkdownTextEditorCommand) -> Void

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
        }
        .monknotChromeSubrowLayout(theme: theme, zoomScale: zoomScale)
    }

    private var regularToolbar: some View {
        HStack(spacing: scaled(6)) {
            expandedHeadingMenu
            divider
            toolbarButton("bold", "Bold", .bold)
            toolbarButton("italic", "Italic", .italic)
            toolbarButton("quote.opening", "Quote", .quote)
            toolbarButton("curlybraces", "Code", .code)
            toolbarButton("link", "Link", .link)
            divider
            toolbarButton("list.bullet", "Bullet List", .bulletList)
            toolbarButton("list.number", "Numbered List", .numberedList)
            toolbarButton("checklist", "Task List", .taskList)
            divider
            toolbarButton("photo", "Image", .image)
            toolbarButton("minus", "Horizontal Rule", .horizontalRule)
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
        headingMenu(width: scaled(148))
    }

    private var compactHeadingMenu: some View {
        headingMenu(width: scaled(118))
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
                height: MonknotMetrics.interfaceControl(26, theme: theme, zoomScale: zoomScale)
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
            if includesLink {
                Button("Link", systemImage: "link") { sendCommand(.link) }
            }
            Button("Quote", systemImage: "quote.opening") { sendCommand(.quote) }
            Button("Inline Code", systemImage: "curlybraces") { sendCommand(.code) }

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
        let dimension = max(
            24,
            MonknotMetrics.interfaceControl(24, theme: theme, zoomScale: zoomScale)
        )
        let shape = RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale))

        return Image(systemName: systemImage)
            .font(.system(size: glyphScaled(12), weight: .medium))
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
            size: .compact,
            action: { sendCommand(command) }
        )
    }
}
