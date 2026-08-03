import MonknotCore
import SwiftUI

struct MonknotCommandOverlay<Content: View>: View {
    let theme: AppTheme
    let zoomScale: Double
    let panelHeight: CGFloat
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(theme.isDark ? 0.34 : 0.16)
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)

                content()
                    .frame(
                        width: max(1, min(scaled(560), geometry.size.width - scaled(32))),
                        height: max(1, min(panelHeight, geometry.size.height - scaled(106))),
                        alignment: .top
                    )
                    .background(
                        RoundedRectangle(cornerRadius: theme.chromeRadius(10, zoomScale: zoomScale))
                            .fill(theme.elevatedSurfaceColor)
                            .shadow(
                                color: .black.opacity(theme.isDark ? 0.44 : 0.12),
                                radius: scaled(16),
                                y: scaled(6)
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: theme.chromeRadius(10, zoomScale: zoomScale)))
                    .padding(.top, scaled(74))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct MonknotCommandOverlayEmptyState: View {
    let title: String
    let message: String
    let theme: AppTheme
    let zoomScale: Double

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(4)) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.foregroundColor)
            Text(message)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(theme.tertiaryForegroundColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, scaled(14))
        .padding(.vertical, scaled(16))
    }
}

struct MonknotCommandOverlayEscapeButton: View {
    let theme: AppTheme
    let close: () -> Void

    var body: some View {
        Button(action: close) {
            Text("esc")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.tertiaryForegroundColor)
                .frame(minWidth: 26, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Close")
        .accessibilityLabel("Close")
    }
}
