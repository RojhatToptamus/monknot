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
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            VStack(spacing: 0) {
                searchField

                Divider()
                    .overlay(theme.borderColor)

                resultBody
            }
            .frame(width: scaled(520))
            .frame(maxHeight: scaled(380))
            .background(
                RoundedRectangle(cornerRadius: theme.chromeRadius(12, zoomScale: zoomScale))
                    .fill(theme.surfaceColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.chromeRadius(12, zoomScale: zoomScale))
                    .strokeBorder(theme.borderColor, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: scaled(18), y: scaled(8))
        }
        .onAppear { focusSearchField() }
        .onChange(of: state.focusSerial) { _, _ in
            focusSearchField()
        }
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

            MonknotIconButton(
                systemImage: "xmark",
                label: "Close Go to Symbol",
                theme: theme,
                zoomScale: zoomScale,
                size: .compact,
                action: close
            )
        }
        .padding(.horizontal, scaled(14))
        .padding(.vertical, scaled(12))
    }

    private var resultBody: some View {
        ScrollView {
            if state.matches.isEmpty {
                Text(state.query.isEmpty ? "No headings in this document" : "No matching headings")
                    .font(.system(size: scaled(12), weight: .medium))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, scaled(14))
                    .padding(.vertical, scaled(16))
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
