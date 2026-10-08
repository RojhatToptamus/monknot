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
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        MonknotCommandOverlay(
            theme: theme,
            zoomScale: zoomScale,
            panelHeight: MonknotCommandOverlayMetrics.panelHeight(
                rows: state.matches.count,
                hasFooter: true,
                theme: theme,
                zoomScale: zoomScale
            ),
            close: close
        ) {
            VStack(spacing: 0) {
                MonknotCommandOverlayField(
                    systemImage: "magnifyingglass",
                    placeholder: "Open file by name…",
                    text: Binding(
                        get: { state.query },
                        set: { state.setQuery($0, documents: documents) }
                    ),
                    isFocused: $isSearchFocused,
                    theme: theme,
                    zoomScale: zoomScale,
                    submit: {
                        if let selected = state.selectedMatch {
                            openDocument(selected.id)
                        }
                    },
                    close: close
                )

                Rectangle().fill(theme.separatorColor).frame(height: 1)

                resultBody

                if !state.matches.isEmpty {
                    MonknotCommandOverlayFooter(
                        hints: [
                            .init(keys: "↑↓", action: "Choose"),
                            .init(keys: "↩", action: "Open"),
                            .init(keys: "Esc", action: "Close"),
                        ],
                        trailing: "\(state.matches.count) of \(documents.count) files",
                        theme: theme,
                        zoomScale: zoomScale
                    )
                }
            }
        }
        .onAppear { focusSearchField() }
        .onChange(of: state.focusSerial) { _, _ in
            focusSearchField()
        }
    }

    private var resultBody: some View {
        ScrollViewReader { proxy in
            MonknotScrollView {
                if state.matches.isEmpty {
                    MonknotCommandOverlayEmptyState(
                        title: state.query.isEmpty
                            ? "Open a file by name"
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
                            MonknotCommandOverlayRow(
                                leading: .glyph(document.kind.resolvedSystemImage),
                                title: document.displayName,
                                detail: (document.relativePath as NSString).deletingLastPathComponent,
                                isSelected: index == state.selectedIndex,
                                theme: theme,
                                zoomScale: zoomScale
                            ) {
                                openDocument(document.id)
                            }
                        }
                    }
                    .padding(scaled(6))
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: state.selectedIndex) { _, _ in
                if let selected = state.selectedMatch {
                    proxy.scrollTo(selected.id)
                }
            }
        }
    }

    private func focusSearchField() {
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }
}
