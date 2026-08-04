import MonknotCore
import SwiftUI

/// Shared chrome/toolbar icon button used across sidebar, top bar, PDF, and find UI.
struct MonknotIconButton: View {
    let systemImage: String
    let label: String
    let theme: AppTheme
    let zoomScale: Double
    var isActive: Bool = false
    var isDisabled: Bool = false
    var size: IconButtonSize = .chrome
    let action: () -> Void

    @State private var isHovered = false

    enum IconButtonSize {
        case chrome
        case windowNavigation
        case sidebarHeader
        case compact
        case findBar
        case segmented

        func dimension(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome, .windowNavigation:
                return MonknotMetrics.chromeButtonDimension(theme: theme, zoomScale: zoomScale)
            case .sidebarHeader:
                return max(22, MonknotMetrics.interfaceControl(22, theme: theme, zoomScale: zoomScale))
            case .compact:
                return max(26, MonknotMetrics.interfaceControl(26, theme: theme, zoomScale: zoomScale))
            case .findBar:
                return max(24, MonknotMetrics.interfaceControl(24, theme: theme, zoomScale: zoomScale))
            case .segmented:
                return max(28, MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoomScale))
            }
        }

        func height(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .windowNavigation:
                return max(22, MonknotMetrics.interfaceControl(24, theme: theme, zoomScale: zoomScale))
            case .chrome, .sidebarHeader, .compact, .findBar, .segmented:
                return dimension(theme: theme, zoomScale: zoomScale)
            }
        }

        func iconSize(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome, .windowNavigation:
                return MonknotMetrics.chromeGlyphSize(theme: theme, zoomScale: zoomScale)
            case .sidebarHeader:
                return MonknotMetrics.interfaceGlyph(
                    MonknotMetrics.sidebarIconPointSizeBase,
                    theme: theme,
                    zoomScale: zoomScale
                )
            case .compact, .findBar:
                return MonknotMetrics.interfaceGlyph(12, theme: theme, zoomScale: zoomScale)
            case .segmented:
                return MonknotMetrics.interfaceGlyph(11, theme: theme, zoomScale: zoomScale)
            }
        }

        var iconWeight: Font.Weight {
            switch self {
            case .sidebarHeader:
                return MonknotMetrics.sidebarIconWeight
            case .findBar:
                return .semibold
            case .chrome, .windowNavigation, .compact, .segmented:
                return .medium
            }
        }

        func cornerRadius(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome:
                return theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale)
            case .windowNavigation, .sidebarHeader, .compact, .findBar:
                return theme.chromeRadius(6, zoomScale: zoomScale)
            case .segmented:
                return theme.chromeRadius(5, zoomScale: zoomScale)
            }
        }

        func hoverBackgroundOpacity(isDark: Bool) -> Double {
            switch self {
            case .windowNavigation:
                return isDark ? 0.06 : 0.055
            case .chrome, .sidebarHeader, .compact, .findBar, .segmented:
                return isDark ? 0.06 : 0.055
            }
        }

        func activeBackgroundOpacity(isDark: Bool) -> Double {
            isDark ? 0.06 : 0.055
        }

        func backgroundOpacity(isHovered: Bool, isDisabled: Bool, isDark: Bool) -> Double? {
            guard isHovered, !isDisabled else { return nil }
            return hoverBackgroundOpacity(isDark: isDark)
        }

        var disabledControlOpacity: Double {
            switch self {
            case .windowNavigation:
                return 0.24
            case .chrome, .sidebarHeader, .compact, .findBar, .segmented:
                return 0.24
            }
        }

    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(
                    size: size.iconSize(theme: theme, zoomScale: zoomScale),
                    weight: size.iconWeight
                ))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(iconColor)
                .frame(
                    width: size.dimension(theme: theme, zoomScale: zoomScale),
                    height: size.height(theme: theme, zoomScale: zoomScale)
                )
                .background {
                    if isActive, !isDisabled {
                        RoundedRectangle(cornerRadius: size.cornerRadius(theme: theme, zoomScale: zoomScale))
                            .fill(theme.foregroundColor.opacity(size.activeBackgroundOpacity(isDark: theme.isDark)))
                    } else if let opacity = size.backgroundOpacity(
                        isHovered: isHovered,
                        isDisabled: isDisabled,
                        isDark: theme.isDark
                    ) {
                        RoundedRectangle(cornerRadius: size.cornerRadius(theme: theme, zoomScale: zoomScale))
                            .fill(theme.foregroundColor.opacity(opacity))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: size.cornerRadius(theme: theme, zoomScale: zoomScale)))
        }
        .buttonStyle(MonknotControlPressStyle())
        .focusEffectDisabled()
        .disabled(isDisabled)
        .opacity(isDisabled ? size.disabledControlOpacity : 1)
        .onHover { isHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .animation(MonknotMotion.hoverAnimation, value: isActive)
        .help(label)
        .accessibilityLabel(label)
        .monknotPointerCursor(enabled: !isDisabled)
    }

    private var iconColor: Color {
        if isDisabled {
            return theme.foregroundColor
        }
        if isActive {
            return theme.foregroundColor
        }
        if isHovered {
            return theme.foregroundColor.opacity(0.92)
        }
        return theme.mutedForegroundColor
    }
}

struct MonknotControlPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(MonknotMotion.hoverAnimation, value: configuration.isPressed)
    }
}

/// Backward-compatible alias used across existing views during migration.
typealias ChromeBarButton = MonknotIconButton

/// Shared trailing close affordance for document and terminal tabs.
struct MonknotTabCloseButton: View {
    let label: String
    let theme: AppTheme
    let zoomScale: Double
    var isVisible = true
    var isDisabled = false
    let action: () -> Void

    @State private var isHovered = false

    private var dimension: CGFloat {
        max(16, MonknotMetrics.interfaceControl(16, theme: theme, zoomScale: zoomScale))
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(
                    size: MonknotMetrics.interfaceGlyph(10.5, theme: theme, zoomScale: zoomScale),
                    weight: .medium
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

extension MonknotIconButton {
    init(
        systemImage: String,
        label: String,
        theme: AppTheme,
        zoomScale: Double,
        uiFontSize: Double,
        isActive: Bool = false,
        isDisabled: Bool = false,
        size: IconButtonSize = .chrome,
        action: @escaping () -> Void
    ) {
        self.init(
            systemImage: systemImage,
            label: label,
            theme: theme,
            zoomScale: zoomScale,
            isActive: isActive,
            isDisabled: isDisabled,
            size: size,
            action: action
        )
    }
}
