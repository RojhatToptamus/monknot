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
        let resultHeight = state.matches.isEmpty
            ? CGFloat(54)
            : CGFloat(visibleRows) * 38 + 12
        return min(scaled(380), scaled(52 + resultHeight))
    }

    private var searchField: some View {
        HStack(spacing: scaled(8)) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: scaled(14), weight: .medium))
                .foregroundStyle(theme.mutedForegroundColor)

            TextField(
                "Go to heading...",
                text: Binding(
                    get: { state.query },
                    set: { state.setQuery($0, items: items) }
                )
            )
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            .font(.system(size: scaled(14)))
            .foregroundStyle(theme.foregroundColor)
            .onSubmit {
                if let first = state.matches.first {
                    selectItem(first)
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
                        ? "No headings in this document"
                        : "No headings match “\(state.query)”",
                    message: state.query.isEmpty
                        ? "Add a Markdown heading, then try again."
                        : "Try a shorter part of the heading name.",
                    theme: theme,
                    zoomScale: zoomScale
                )
            } else {
                LazyVStack(alignment: .leading, spacing: scaled(2)) {
                    ForEach(state.matches) { item in
                        Button {
                            selectItem(item)
                        } label: {
                            HStack(spacing: scaled(8)) {
                                Text(String(repeating: "·", count: max(1, item.level - 1)))
                                    .font(.system(size: scaled(11), weight: .bold, design: .monospaced))
                                    .foregroundStyle(theme.mutedForegroundColor)
                                    .frame(width: scaled(18), alignment: .leading)

                                Text(item.title)
                                    .font(.system(size: scaled(13), weight: .medium))
                                    .foregroundStyle(theme.foregroundColor)
                                    .lineLimit(1)

                                Spacer(minLength: 0)

                                Text(":\(item.location.line)")
                                    .font(.system(size: scaled(10), weight: .medium, design: .monospaced))
                                    .foregroundStyle(theme.mutedForegroundColor)
                            }
                            .padding(.horizontal, scaled(12))
                            .padding(.vertical, scaled(8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, scaled(6))
            }
        }
    }

    private func focusSearchField() {
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }
}
