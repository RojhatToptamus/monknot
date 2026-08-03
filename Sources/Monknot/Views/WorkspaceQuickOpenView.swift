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
            }
        }
        .onAppear { focusSearchField() }
        .onChange(of: state.focusSerial) { _, _ in
            focusSearchField()
        }
    }

    private var panelHeight: CGFloat {
        let visibleRows = min(max(state.matches.count, 1), 8)
        let resultHeight = state.matches.isEmpty ? CGFloat(78) : CGFloat(visibleRows) * 48 + 12
        return scaled(52 + resultHeight)
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
                close: close
            )
        }
        .padding(.horizontal, scaled(14))
        .padding(.vertical, scaled(12))
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

                                VStack(alignment: .leading, spacing: scaled(2)) {
                                    Text(document.displayName)
                                        .font(.system(size: scaled(13), weight: .medium))
                                        .foregroundStyle(theme.foregroundColor)
                                        .lineLimit(1)

                                    Text(document.relativePath)
                                        .font(.system(size: scaled(11)))
                                        .foregroundStyle(theme.mutedForegroundColor)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, scaled(12))
                            .padding(.vertical, scaled(8))
                            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func focusSearchField() {
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }
}
