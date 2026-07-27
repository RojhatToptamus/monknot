import MonknotCore
import SwiftUI

struct MarkdownOutlinePanel: View {
    let items: [MarkdownOutlineItem]
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let select: (MarkdownOutlineItem) -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: scaled(8)) {
                Image(systemName: MonknotWorkspaceIcons.outline)
                    .foregroundStyle(theme.accentColor)
                Text("Outline")
                    .font(.system(size: scaled(13), weight: .semibold))
                    .foregroundStyle(theme.foregroundColor)
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: scaled(11), weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.mutedForegroundColor)
            }
            .padding(.horizontal, scaled(14))
            .padding(.vertical, scaled(10))

            Divider()
                .overlay(theme.borderColor)

            if items.isEmpty {
                VStack(alignment: .leading, spacing: scaled(8)) {
                    Text("No headings")
                        .font(.system(size: scaled(13), weight: .semibold))
                        .foregroundStyle(theme.foregroundColor)
                    Text("Markdown headings will appear here.")
                        .font(.system(size: scaled(12)))
                        .foregroundStyle(theme.mutedForegroundColor)
                }
                .padding(scaled(14))
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MonknotScrollView {
                    LazyVStack(alignment: .leading, spacing: scaled(1)) {
                        ForEach(items) { item in
                            Button {
                                select(item)
                            } label: {
                                HStack(spacing: scaled(7)) {
                                    Text(item.title)
                                        .font(.system(size: scaled(12), weight: .regular))
                                        .foregroundStyle(theme.foregroundColor)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text("\(item.location.line)")
                                        .font(.system(size: scaled(10), weight: .medium, design: .monospaced))
                                        .foregroundStyle(theme.mutedForegroundColor)
                                }
                                .padding(.leading, scaled(CGFloat(max(0, item.level - 1)) * 12 + 10))
                                .padding(.trailing, scaled(10))
                                .padding(.vertical, scaled(6))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(OutlineRowButtonStyle(theme: theme, cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale)))
                        }
                    }
                    .padding(scaled(6))
                }
                .frame(maxHeight: scaled(320))
            }
        }
        .frame(width: scaled(320))
        .background(theme.elevatedSurfaceColor)
    }
}

private struct OutlineRowButtonStyle: ButtonStyle {
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
                        .fill(isHovered ? theme.foregroundColor.opacity(theme.isDark ? 0.08 : 0.055) : Color.clear)
                )
                .opacity(configuration.isPressed ? 0.86 : 1)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .monknotPointerCursor()
        }
    }
}
