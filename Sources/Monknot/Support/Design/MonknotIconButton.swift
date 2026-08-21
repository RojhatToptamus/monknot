import MonknotCore
import SwiftUI

extension View {
    /// Installs help only when a meaningful inactive-control hint exists.
    /// Passing `nil` avoids creating an empty tooltip surface.
    @ViewBuilder
    func monknotHelp(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            help(text)
        } else {
            self
        }
    }
}

/// Shared chrome/toolbar icon button used across sidebar, top bar, PDF, and find UI.
struct MonknotIconButton: View {
    static let focusRingLineWidth: CGFloat = 3
    static let focusRingOutset: CGFloat = 2
    static let focusRingOpacity = 0.35

    static func showsFocusRing(isFocused: Bool, isDisabled: Bool) -> Bool {
        isFocused && !isDisabled
    }

    let systemImage: String
    let label: String
    let theme: AppTheme
    let zoomScale: Double
    var isActive: Bool = false
    var isDisabled: Bool = false
    var size: IconButtonSize = .chrome
    var drawsBorder = false
    var drawsActiveBackground = true
    var focusRingPlacement: FocusRingPlacement = .outside
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    enum FocusRingPlacement {
        case outside
        case contained
    }

    enum IconButtonSize {
        case chrome
        case windowNavigation
        case sidebarHeader
        case compact
        case editorToolbar
        case findBar
        case segmented

        func dimension(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome:
                return MonknotMetrics.chromeButtonDimension(theme: theme, zoomScale: zoomScale)
            case .windowNavigation:
                return MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoomScale)
            case .compact:
                return MonknotMetrics.interfaceControl(26, theme: theme, zoomScale: zoomScale)
            case .editorToolbar:
                return MonknotMetrics.interfaceControl(30, theme: theme, zoomScale: zoomScale)
            case .sidebarHeader:
                return MonknotMetrics.interfaceControl(22, theme: theme, zoomScale: zoomScale)
            case .findBar:
                return MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoomScale)
            case .segmented:
                return MonknotMetrics.interfaceControl(30, theme: theme, zoomScale: zoomScale)
            }
        }

        func height(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .windowNavigation:
                return MonknotMetrics.interfaceControl(22, theme: theme, zoomScale: zoomScale)
            case .chrome, .sidebarHeader, .compact, .editorToolbar, .findBar, .segmented:
                return dimension(theme: theme, zoomScale: zoomScale)
            }
        }

        func iconSize(theme: AppTheme, zoomScale: Double) -> CGFloat {
            MonknotMetrics.interfaceGlyph(
                iconPointSizeBase,
                theme: theme,
                zoomScale: zoomScale
            )
        }

        var iconPointSizeBase: CGFloat {
            switch self {
            case .chrome:
                return MonknotMetrics.iconPointSizeBase
            case .windowNavigation:
                return 16
            case .sidebarHeader:
                return 16
            case .compact:
                return 16
            case .findBar:
                return 17
            case .editorToolbar:
                return 17
            case .segmented:
                return 18
            }
        }

        var iconWeight: Font.Weight {
            .regular
        }

        func cornerRadius(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome:
                return theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale)
            case .sidebarHeader, .compact, .editorToolbar, .findBar:
                return theme.chromeRadius(8, zoomScale: zoomScale)
            case .windowNavigation:
                return theme.chromeRadius(6, zoomScale: zoomScale)
            case .segmented:
                return theme.chromeRadius(5, zoomScale: zoomScale)
            }
        }

        func hoverBackgroundOpacity(isDark: Bool) -> Double {
            switch self {
            case .windowNavigation:
                return isDark ? 0.06 : 0.055
            case .chrome, .sidebarHeader, .compact, .editorToolbar, .findBar, .segmented:
                return isDark ? 0.06 : 0.055
            }
        }

        func activeBackgroundOpacity(isDark: Bool) -> Double {
            isDark ? 0.18 : 0.14
        }

        func backgroundOpacity(
            isActive: Bool = false,
            drawsActiveBackground: Bool = true,
            isHovered: Bool,
            isDisabled: Bool,
            isDark: Bool
        ) -> Double? {
            guard !isDisabled else { return nil }
            if isActive, drawsActiveBackground {
                return activeBackgroundOpacity(isDark: isDark)
            }
            if isHovered {
                return hoverBackgroundOpacity(isDark: isDark)
            }
            return nil
        }

        var disabledControlOpacity: Double {
            switch self {
            case .windowNavigation:
                return 0.24
            case .chrome, .sidebarHeader, .compact, .editorToolbar, .findBar, .segmented:
                return 0.24
            }
        }

    }

    var body: some View {
        Button(action: action) {
            MonknotSystemGlyph(
                systemImage: systemImage,
                nominalPointSizeBase: size.iconPointSizeBase,
                theme: theme,
                zoomScale: zoomScale
            )
                .foregroundStyle(iconColor)
                .frame(
                    width: size.dimension(theme: theme, zoomScale: zoomScale),
                    height: size.height(theme: theme, zoomScale: zoomScale)
                )
                .background {
                    if let opacity = size.backgroundOpacity(
                        isActive: isActive,
                        drawsActiveBackground: drawsActiveBackground,
                        isHovered: isHovered,
                        isDisabled: isDisabled,
                        isDark: theme.isDark
                    ) {
                        RoundedRectangle(cornerRadius: size.cornerRadius(theme: theme, zoomScale: zoomScale))
                            .fill(theme.foregroundColor.opacity(opacity))
                    }
                }
                .overlay {
                    if Self.showsFocusRing(isFocused: isFocused, isDisabled: isDisabled) {
                        focusRing
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: size.cornerRadius(theme: theme, zoomScale: zoomScale)))
        }
        .buttonStyle(MonknotIconButtonPressStyle(
            theme: theme,
            cornerRadius: size.cornerRadius(theme: theme, zoomScale: zoomScale),
            isDisabled: isDisabled
        ))
        .focusable(!isDisabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .disabled(isDisabled)
        .opacity(isDisabled ? size.disabledControlOpacity : 1)
        .overlay {
            if drawsBorder {
                RoundedRectangle(cornerRadius: size.cornerRadius(theme: theme, zoomScale: zoomScale))
                    .strokeBorder(
                        isActive
                            ? theme.accentColor.opacity(theme.isDark ? 0.38 : 0.30)
                            : theme.borderColor,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
        }
        .onHover { isHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .animation(MonknotMotion.hoverAnimation, value: isActive)
        .help(label)
        .accessibilityLabel(label)
        .monknotPointerCursor(enabled: !isDisabled)
    }

    private var iconColor: Color {
        if isDisabled {
            return theme.disabledForegroundColor
        }
        if isActive {
            return theme.accentColor
        }
        if isHovered {
            return theme.foregroundColor.opacity(0.92)
        }
        return theme.mutedForegroundColor
    }

    @ViewBuilder
    private var focusRing: some View {
        switch focusRingPlacement {
        case .outside:
            RoundedRectangle(cornerRadius: size.cornerRadius(theme: theme, zoomScale: zoomScale))
                .stroke(
                    theme.accentColor.opacity(Self.focusRingOpacity),
                    lineWidth: Self.focusRingLineWidth
                )
                .padding(-Self.focusRingOutset)
                .allowsHitTesting(false)
        case .contained:
            RoundedRectangle(cornerRadius: size.cornerRadius(theme: theme, zoomScale: zoomScale))
                .strokeBorder(
                    theme.accentColor.opacity(Self.focusRingOpacity),
                    lineWidth: Self.focusRingLineWidth
                )
                .allowsHitTesting(false)
        }
    }
}

private struct MonknotIconButtonPressStyle: ButtonStyle {
    let theme: AppTheme
    let cornerRadius: CGFloat
    let isDisabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed, !isDisabled {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(theme.foregroundColor.opacity(theme.isDark ? 0.12 : 0.10))
                }
            }
            .opacity(configuration.isPressed && !isDisabled ? 0.88 : 1)
            .animation(MonknotMotion.hoverAnimation, value: configuration.isPressed)
    }
}

struct MonknotControlPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(MonknotMotion.hoverAnimation, value: configuration.isPressed)
    }
}

/// Shared trailing close affordance for document and terminal tabs.
struct MonknotTabCloseButton: View {
    let label: String
    let theme: AppTheme
    let zoomScale: Double
    var isVisible = true
    var isDisabled = false
    let action: () -> Void

    @State private var isHovered = false

    static func dimension(theme: AppTheme, zoomScale: Double) -> CGFloat {
        MonknotMetrics.interfaceControl(16, theme: theme, zoomScale: zoomScale)
    }

    private var dimension: CGFloat {
        Self.dimension(theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(
                    size: MonknotMetrics.interfaceGlyph(11, theme: theme, zoomScale: zoomScale),
                    weight: .regular
                ))
                .foregroundStyle(
                    isHovered
                        ? theme.foregroundColor.opacity(0.86)
                        : theme.mutedForegroundColor.opacity(0.72)
                )
                .frame(width: dimension, height: dimension)
                .background {
                    if isHovered {
                        Circle().fill(theme.foregroundColor.opacity(0.11))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isDisabled || !isVisible)
        .opacity(isVisible ? 1 : 0)
        .onHover { isHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHidden(!isVisible)
        .monknotPointerCursor(enabled: isVisible && !isDisabled)
    }
}
