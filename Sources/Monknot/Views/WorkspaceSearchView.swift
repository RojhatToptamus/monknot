import MonknotCore
import AppKit
import SwiftUI

struct WorkspaceSearchView: View {
    @ObservedObject var state: WorkspaceSearchState
    let documents: [WorkspaceDocument]
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let close: () -> Void
    let openResult: (WorkspaceSearchResult) -> Void

    @FocusState private var isSearchFocused: Bool

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider()
                .overlay(theme.borderColor)

            searchBody
        }
        .onAppear {
            focusSearchField()
        }
        .onChange(of: state.focusSerial) { _, _ in
            focusSearchField()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            HStack(spacing: scaled(8)) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: scaled(14), weight: .medium))
                    .foregroundStyle(theme.sidebarColor(theme.mutedForegroundColor))

                TextField(
                    "Search workspace...",
                    text: Binding(
                        get: { state.query },
                        set: { state.setQuery($0, documents: documents) }
                    )
                )
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .font(.system(size: scaled(13)))
                .foregroundStyle(theme.sidebarColor(theme.foregroundColor))
                .onSubmit {
                    if let first = state.results.first {
                        openResult(first)
                    }
                }

                MonknotIconButton(
                    systemImage: "xmark",
                    label: "Close Search",
                    theme: theme,
                    zoomScale: zoomScale,
                    size: .compact,
                    action: close
                )
            }
            .padding(.horizontal, scaled(10))
            .padding(.vertical, scaled(7))
            .background(
                theme.insetFillColor,
                in: RoundedRectangle(cornerRadius: theme.chromeRadius(9, zoomScale: zoomScale))
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.chromeRadius(9, zoomScale: zoomScale))
                    .strokeBorder(theme.borderColor, lineWidth: 1)
            }

            Text(state.errorMessage ?? state.resultCountText)
                .font(.system(size: scaled(11), weight: .medium))
                .foregroundStyle(state.errorMessage == nil ? theme.sidebarColor(theme.mutedForegroundColor) : Color(hex: theme.semanticColors.diffRemoved))
                .lineLimit(1)
        }
        .padding(.horizontal, scaled(12))
        .padding(.vertical, scaled(10))
    }

    private var searchBody: some View {
        ScrollView {
            if state.results.isEmpty {
                emptyState
            } else {
                resultList
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var resultList: some View {
        LazyVStack(alignment: .leading, spacing: scaled(2)) {
            ForEach(state.results) { result in
                Button {
                    openResult(result)
                } label: {
                    VStack(alignment: .leading, spacing: scaled(2)) {
                        HStack(spacing: scaled(6)) {
                            Image(systemName: result.kind.resolvedSystemImage)
                                .font(.system(size: scaled(12)))
                                .foregroundStyle(theme.sidebarColor(theme.mutedForegroundColor, opacity: 0.72))

                            Text(result.displayName)
                                .font(.system(size: scaled(12), weight: .medium))
                                .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: 0.92))
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            Text(result.locationLabel)
                                .font(.system(size: scaled(10), weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.sidebarColor(theme.mutedForegroundColor))
                        }

                        Text(highlightedPreview(for: result))
                            .font(.system(size: scaled(11)))
                            .foregroundStyle(theme.sidebarColor(theme.mutedForegroundColor))
                            .lineLimit(2)
                    }
                    .padding(.horizontal, scaled(9))
                    .padding(.vertical, scaled(7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SidebarSearchResultButtonStyle(theme: theme, cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)))
            }
        }
        .padding(.horizontal, scaled(6))
        .padding(.vertical, scaled(6))
    }

    private func highlightedPreview(for result: WorkspaceSearchResult) -> AttributedString {
        let text = result.preview
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributed = NSMutableAttributedString(string: text)

        guard !query.isEmpty else {
            return AttributedString(attributed)
        }

        let nsText = text as NSString
        var searchRange = NSRange(location: 0, length: nsText.length)
        let highlightColor = NSColor(hex: theme.accent).withAlphaComponent(theme.isDark ? 0.32 : 0.22)

        while searchRange.length > 0 {
            let found = nsText.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )

            guard found.location != NSNotFound, found.length > 0 else { break }
            attributed.addAttribute(.backgroundColor, value: highlightColor, range: found)

            let nextLocation = found.location + found.length
            guard nextLocation < nsText.length else { break }
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }

        return AttributedString(attributed)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            Image(systemName: state.isSearching ? "hourglass" : "doc.text.magnifyingglass")
                .font(.system(size: scaled(20), weight: .regular))
                .foregroundStyle(theme.sidebarColor(theme.mutedForegroundColor))

            Text(state.isSearching ? "Searching" : "No results")
                .font(.system(size: scaled(13), weight: .semibold))
                .foregroundStyle(theme.sidebarColor(theme.foregroundColor))

            Text(state.query.isEmpty ? "Search across text and PDF files in this workspace." : "No searchable matches found.")
                .font(.system(size: scaled(12)))
                .foregroundStyle(theme.sidebarColor(theme.mutedForegroundColor))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(scaled(16))
    }

    private func focusSearchField() {
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }
}

private struct SidebarSearchResultButtonStyle: ButtonStyle {
    let theme: AppTheme
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, theme: theme, cornerRadius: cornerRadius)
    }

    fileprivate struct Body: View {
        let configuration: Configuration
        let theme: AppTheme
        let cornerRadius: CGFloat
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(backgroundFill)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(configuration.isPressed ? theme.borderColor : Color.clear, lineWidth: 1)
                }
                .opacity(configuration.isPressed ? 0.88 : 1)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .onHover { isHovered = $0 }
                .monknotPointerCursor()
        }

        private var backgroundFill: Color {
            if configuration.isPressed {
                return theme.selectedRowColor
            }
            if isHovered {
                return theme.foregroundColor.opacity(theme.isDark ? 0.08 : 0.055)
            }
            return .clear
        }
    }
}
