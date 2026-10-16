import MonknotCore
import SwiftUI

struct MarkdownSymbolQuickOpenView: View {
    @ObservedObject var state: MarkdownSymbolQuickOpenState
    let items: [MarkdownOutlineItem]
    let theme: AppTheme
    let zoomScale: Double
    let close: () -> Void
    let selectItem: (MarkdownOutlineItem) -> Void

    @FocusState private var isSearchFocused: Bool

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
                    systemImage: "list.bullet.indent",
                    placeholder: "Go to heading…",
                    text: Binding(
                        get: { state.query },
                        set: { state.setQuery($0, items: items) }
                    ),
                    isFocused: $isSearchFocused,
                    theme: theme,
                    zoomScale: zoomScale,
                    submit: {
                        if let selected = state.selectedMatch {
                            selectItem(selected)
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
                            .init(keys: "↩", action: "Go"),
                            .init(keys: "Esc", action: "Close"),
                        ],
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
        MonknotCommandOverlayResults(
            items: state.matches,
            selectedIndex: state.selectedIndex,
            emptyTitle: state.query.isEmpty
                ? "No headings in this document"
                : "No headings match “\(state.query)”",
            emptyMessage: state.query.isEmpty
                ? "Add a Markdown heading, then try again."
                : "Try a shorter part of the heading name.",
            theme: theme,
            zoomScale: zoomScale
        ) { item, isSelected in
            MonknotCommandOverlayRow(
                leading: .tag("H\(item.level)"),
                title: item.title,
                trailing: "\(item.location.line)",
                isSelected: isSelected,
                theme: theme,
                zoomScale: zoomScale
            ) {
                selectItem(item)
            }
        }
    }

    private func focusSearchField() {
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }
}
