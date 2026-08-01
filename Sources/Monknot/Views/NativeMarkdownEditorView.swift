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

    private var scale: CGFloat {
        theme.layoutScale(zoomScale: zoomScale)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6 * scale) {
                headingMenu
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
            .padding(.vertical, 4 * scale)
        }
        .monknotChromeSubrowLayout(theme: theme, zoomScale: zoomScale)
    }

    private var headingMenu: some View {
        let shape = RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale))

        return Menu {
            Button("Paragraph") { sendCommand(.paragraph) }
            Divider()
            Button("Heading 1") { sendCommand(.heading(level: 1)) }
            Button("Heading 2") { sendCommand(.heading(level: 2)) }
            Button("Heading 3") { sendCommand(.heading(level: 3)) }
        } label: {
            HStack(spacing: 7 * scale) {
                Text("Paragraph")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundStyle(theme.mutedForegroundColor)
            }
            .foregroundStyle(theme.foregroundColor)
            .padding(.horizontal, 10 * scale)
            .frame(width: 148 * scale, height: 26 * scale)
            .background(shape.fill(theme.controlTrackFillColor))
            .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Block Style")
        .accessibilityLabel("Block Style")
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.borderColor)
            .frame(width: 1, height: 20 * scale)
            .padding(.horizontal, 2 * scale)
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
