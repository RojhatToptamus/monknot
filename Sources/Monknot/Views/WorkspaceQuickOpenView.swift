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
            .frame(width: scaled(560))
            .frame(maxHeight: scaled(420))
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
            Image(systemName: "doc.text.magnifyingglass")
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

            MonknotIconButton(
                systemImage: "xmark",
                label: "Close Quick Open",
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
                Text(state.query.isEmpty ? "Type to filter workspace files" : "No matching files")
                    .font(.system(size: scaled(12), weight: .medium))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, scaled(14))
                    .padding(.vertical, scaled(16))
            } else {
                LazyVStack(alignment: .leading, spacing: scaled(2)) {
                    ForEach(state.matches) { document in
                        Button {
                            openDocument(document.id)
                        } label: {
                            HStack(spacing: scaled(8)) {
                                Image(systemName: document.kind.resolvedSystemImage)
                                    .font(.system(size: scaled(12)))
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
                                    .fill(theme.insetFillColor.opacity(0.55))
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
