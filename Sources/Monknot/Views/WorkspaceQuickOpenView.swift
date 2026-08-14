import MonknotCore
import SwiftUI

struct WorkspaceQuickOpenView: View {
    @ObservedObject var state: WorkspaceQuickOpenState
    let documents: [WorkspaceDocument]
    let theme: AppTheme
    let zoomScale: Double
    let close: () -> Void
    let openDocument: (String) -> Void

    @FocusState private var isSearchFocused: Bool

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        MonknotCommandOverlay(
            theme: theme,
            zoomScale: zoomScale,
            panelHeight: panelHeight,
            close: close
        ) {
            VStack(spacing: 0) {
                searchField

                Divider()
                    .overlay(theme.separatorColor)

                resultBody

                if !state.matches.isEmpty {
                    resultFooter
                }
            }
        }
        .onAppear { focusSearchField() }
        .onChange(of: state.focusSerial) { _, _ in
            focusSearchField()
        }
    }

    private var panelHeight: CGFloat {
        let visibleRows = min(max(state.matches.count, 1), 8)
        let resultHeight = state.matches.isEmpty ? CGFloat(72) : CGFloat(visibleRows) * 34 + 12
        let footerHeight = state.matches.isEmpty ? CGFloat(0) : CGFloat(28)
        return scaled(44 + resultHeight + footerHeight)
    }

    private var searchField: some View {
        HStack(spacing: scaled(8)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: scaled(14), weight: .medium))
                .foregroundStyle(theme.mutedForegroundColor)

            TextField(
                "Open file by name...",
                text: Binding(
                    get: { state.query },
                    set: { state.setQuery($0, documents: documents) }
                )
            )
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            .font(.system(size: scaled(14)))
            .foregroundStyle(theme.foregroundColor)
            .onSubmit {
                if let first = state.matches.first {
                    openDocument(first.id)
                }
            }

            MonknotCommandOverlayEscapeButton(
                theme: theme,
                zoomScale: zoomScale,
                close: close
            )
        }
        .padding(.horizontal, scaled(14))
        .frame(height: scaled(44))
    }

    private var resultBody: some View {
        MonknotScrollView {
            if state.matches.isEmpty {
                MonknotCommandOverlayEmptyState(
                    title: state.query.isEmpty
                        ? "Open a file by name…"
                        : "No files match “\(state.query)”",
                    message: state.query.isEmpty
                        ? "Start typing to filter workspace files."
                        : "Try part of a name, or ⇧⌘F to search contents.",
                    theme: theme,
                    zoomScale: zoomScale
                )
            } else {
                LazyVStack(alignment: .leading, spacing: scaled(2)) {
                    ForEach(Array(state.matches.enumerated()), id: \.element.id) { index, document in
                        Button {
                            openDocument(document.id)
                        } label: {
                            HStack(spacing: scaled(8)) {
                                Image(systemName: document.kind.resolvedSystemImage)
                                    .font(.system(size: scaled(14), weight: .regular))
                                    .foregroundStyle(theme.mutedForegroundColor)

                                VStack(alignment: .leading, spacing: scaled(1)) {
                                    Text(document.displayName)
                                        .font(.system(size: scaled(13), weight: .regular))
                                        .foregroundStyle(theme.foregroundColor)
                                        .lineLimit(1)

                                    Text(document.relativePath)
                                        .font(.system(size: scaled(10.5)))
                                        .foregroundStyle(theme.tertiaryForegroundColor)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, scaled(12))
                            .frame(maxWidth: .infinity, minHeight: scaled(34), maxHeight: scaled(34), alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                                    .fill(index == 0 ? theme.selectedRowColor : .clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .monknotPointerCursor()
                    }
                }
                .padding(.horizontal, scaled(8))
                .padding(.vertical, scaled(8))
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var resultFooter: some View {
        HStack(spacing: scaled(14)) {
            MonknotShortcutLabel(
                shortcut: "↑↓ Navigate",
                theme: theme,
                zoomScale: zoomScale
            )
            MonknotShortcutLabel(
                shortcut: "↩ Open",
                theme: theme,
                zoomScale: zoomScale
            )
            Spacer(minLength: 0)
            Text("\(state.matches.count) of \(documents.count) files")
                .font(.system(size: scaled(10.5), weight: .regular))
                .foregroundStyle(theme.tertiaryForegroundColor)
        }
        .padding(.horizontal, scaled(14))
        .frame(height: scaled(28))
        .background(theme.contentSurfaceColor)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separatorColor).frame(height: 1)
        }
    }

    private func focusSearchField() {
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }
}
