import MarkprevCore
import SwiftUI

struct EditorPaneView: View {
    @ObservedObject var store: WorkspaceStore
    let editorMode: EditorMode
    let theme: AppTheme
    let zoomScale: Double
    let codeFontSize: CGFloat
    @Binding var sourceLocation: MarkdownSourceLocation?
    let onPreviewSourceJump: (MarkdownSourceLocation) -> Void

    var body: some View {
        Group {
            if let selectedFile = store.selectedFile {
                editor(for: selectedFile)
            } else {
                EmptyDetailView(theme: theme)
            }
        }
        .background(theme.surfaceColor)
    }

    @ViewBuilder
    private func editor(for selectedFile: MarkdownFile) -> some View {
        if editorMode == .source {
            MarkdownTextEditor(
                text: Binding(
                    get: { store.documentText },
                    set: { store.setDocumentText($0) }
                ),
                theme: theme,
                fontSize: codeFontSize * zoomScale,
                sourceLocation: $sourceLocation
            )
            .help(selectedFile.relativePath)
        } else {
            MarkdownPreviewView(
                markdown: store.documentText,
                baseURL: store.workspaceURL,
                theme: theme,
                zoomScale: zoomScale,
                onSourceJump: onPreviewSourceJump
            )
            .help(selectedFile.relativePath)
        }
    }
}

private struct EmptyDetailView: View {
    let theme: AppTheme

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "markdown")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(theme.mutedForegroundColor)

            VStack(spacing: 6) {
                Text("Select a Markdown file")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.foregroundColor)
                Text("Open a folder or drop Markdown files into the sidebar.")
                    .foregroundStyle(theme.mutedForegroundColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
