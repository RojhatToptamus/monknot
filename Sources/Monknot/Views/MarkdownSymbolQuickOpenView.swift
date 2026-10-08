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
            : CGFloat(visibleRows) * 30 + 10
        return min(scaled(380), scaled(44 + resultHeight))
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
            .accessibilityLabel("Go to heading")
            .onSubmit {
                if let selected = state.selectedMatch {
                    selectItem(selected)
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
        ScrollViewReader { proxy in
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
                        ForEach(Array(state.matches.enumerated()), id: \.element.id) { index, item in
                            Button {
                                selectItem(item)
                            } label: {
                                HStack(spacing: scaled(8)) {
                                    Text("H\(item.level)")
                                        .font(.system(size: scaled(10), weight: .regular, design: .monospaced))
                                        .foregroundStyle(theme.mutedForegroundColor)
                                        .frame(width: scaled(18), alignment: .leading)

                                    Text(item.title)
                                        .font(.system(size: scaled(13), weight: .regular))
                                        .foregroundStyle(theme.foregroundColor)
                                        .lineLimit(1)

                                    Spacer(minLength: 0)

                                    Text(":\(item.location.line)")
                                        .font(.system(size: scaled(10), weight: .medium, design: .monospaced))
                                        .foregroundStyle(theme.mutedForegroundColor)
                                }
                                .padding(.horizontal, scaled(10))
                                .frame(maxWidth: .infinity, minHeight: scaled(30), maxHeight: scaled(30), alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                                        .fill(index == state.selectedIndex ? theme.selectedRowColor : .clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(index == state.selectedIndex ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, scaled(8))
                    .padding(.vertical, scaled(6))
                }
            }
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
