import MarkprevCore
import SwiftUI

struct EditorPaneView: View {
    @ObservedObject var store: WorkspaceStore
    let editorMode: EditorMode
    let renderTheme: RenderTheme

    var body: some View {
        Group {
            if let selectedFile = store.selectedFile {
                VStack(spacing: 0) {
                    FileHeaderView(file: selectedFile, hasUnsavedChanges: store.hasUnsavedChanges)

                    Divider()

                    if editorMode == .source {
                        MarkdownTextEditor(
                            text: Binding(
                                get: { store.documentText },
                                set: { store.setDocumentText($0) }
                            ),
                            theme: renderTheme
                        )
                    } else {
                        MarkdownPreviewView(
                            markdown: store.documentText,
                            baseURL: store.workspaceURL,
                            theme: renderTheme
                        )
                    }
                }
            } else {
                EmptyDetailView()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct FileHeaderView: View {
    let file: MarkdownFile
    let hasUnsavedChanges: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.plaintext")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    if hasUnsavedChanges {
                        Circle()
                            .fill(.blue)
                            .frame(width: 7, height: 7)
                            .help("Unsaved changes")
                    }
                }

                Text(file.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "markdown")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("Select a Markdown file")
                    .font(.title2.weight(.semibold))
                Text("Open a folder or drop Markdown files into the sidebar.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
