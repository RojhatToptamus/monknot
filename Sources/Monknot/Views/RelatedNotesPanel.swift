import MonknotCore
import SwiftUI

struct RelatedNotesPanel: View {
    let matches: [RelatedNoteMatch]
    let theme: AppTheme
    let zoomScale: Double
    let openDocument: (String) -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: scaled(6)) {
                Text("Related notes")
                    .font(.system(size: scaled(11), weight: .semibold))
                    .foregroundStyle(theme.mutedForegroundColor)

                ForEach(matches) { match in
                    Button {
                        openDocument(match.relativePath)
                    } label: {
                        HStack(spacing: scaled(8)) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: scaled(11)))
                            VStack(alignment: .leading, spacing: scaled(2)) {
                                Text(match.displayName)
                                    .font(.system(size: scaled(12), weight: .medium))
                                    .lineLimit(1)
                                Text(match.reason)
                                    .font(.system(size: scaled(10)))
                                    .foregroundStyle(theme.mutedForegroundColor)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(theme.foregroundColor.opacity(0.9))
                        .padding(.horizontal, scaled(8))
                        .padding(.vertical, scaled(5))
                        .background(
                            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                                .fill(theme.insetFillColor.opacity(0.55))
                        )
                    }
                    .buttonStyle(.plain)
                    .monknotPointerCursor()
                }
            }
            .padding(.horizontal, scaled(12))
            .padding(.bottom, scaled(8))
        }
    }
}
