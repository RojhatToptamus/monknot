import MonknotCore
import SwiftUI

struct NativeMarkdownEditorView: View {
    let documentID: String
    @Binding var text: String
    let theme: AppTheme
    let fontSize: CGFloat
    let zoomScale: Double
    let fontSmoothing: Bool
    let scrollPosition: DocumentScrollPosition?
    @Binding var sourceLocation: MarkdownSourceLocation?
    @Binding var searchState: DocumentSearchState
    let onScrollPositionChange: (DocumentScrollPosition) -> Void

    @State private var commandSerial = 0
    @State private var commandRequest: MarkdownTextEditorCommandRequest?

    var body: some View {
        VStack(spacing: 0) {
            MarkdownSourceToolbar(
                theme: theme,
                zoomScale: zoomScale,
                sendCommand: sendCommand(_:)
            )

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
                    commandRequest: commandRequest,
                    markdownShortcutsEnabled: true
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
        }
        .background(theme.surfaceColor)
    }

    private func sendCommand(_ command: MarkdownTextEditorCommand) {
        commandSerial += 1
        commandRequest = MarkdownTextEditorCommandRequest(serial: commandSerial, command: command)
    }
}

private struct MarkdownSourceToolbar: View {
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
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 6 * scale)
        }
        .background(theme.surfaceColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.borderColor)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
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
            .frame(width: 148 * scale, height: 28 * scale)
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
            .frame(width: 1, height: 22 * scale)
            .padding(.horizontal, 2 * scale)
    }

    private func toolbarButton(
        _ systemImage: String,
        _ label: String,
        _ command: MarkdownTextEditorCommand
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale))

        return Button {
            sendCommand(command)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13 * scale, weight: .medium))
                .frame(width: 28 * scale, height: 28 * scale)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .frame(width: 28 * scale, height: 28 * scale)
        .contentShape(shape)
        .foregroundStyle(theme.foregroundColor)
        .background(shape.fill(theme.controlTrackFillColor))
        .help(label)
        .accessibilityLabel(label)
    }
}
