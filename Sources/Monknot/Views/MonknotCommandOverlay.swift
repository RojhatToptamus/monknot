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
                        RoundedRectangle(cornerRadius: theme.chromeRadius(16, zoomScale: zoomScale))
                            .fill(theme.elevatedSurfaceColor)
                            .shadow(
                                color: .black.opacity(theme.isDark ? 0.44 : 0.12),
                                radius: 16,
                                y: 6
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: theme.chromeRadius(16, zoomScale: zoomScale)))
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
    let zoomScale: Double
    let close: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var dimension: CGFloat {
        MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoomScale)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
    }

    var body: some View {
        Button(action: close) {
            MonknotShortcutLabel(
                shortcut: "Esc",
                theme: theme,
                zoomScale: zoomScale
            )
            .frame(minWidth: dimension, minHeight: dimension)
            .background {
                if isHovered {
                    shape.fill(theme.foregroundColor.opacity(theme.isDark ? 0.06 : 0.055))
                }
            }
            .overlay {
                if isFocused {
                    shape
                        .stroke(
                            theme.accentColor.opacity(MonknotIconButton.focusRingOpacity),
                            lineWidth: MonknotIconButton.focusRingLineWidth
                        )
                        .padding(-MonknotIconButton.focusRingOutset)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(MonknotControlPressStyle())
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .keyboardShortcut(.cancelAction)
        .help("Close")
        .accessibilityLabel("Close")
        .monknotPointerCursor()
    }
}
