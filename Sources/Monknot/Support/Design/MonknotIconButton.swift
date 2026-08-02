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
    @FocusState private var isFocused: Bool

    enum IconButtonSize {
        case chrome
        case windowNavigation
        case compact
        case findBar
        case segmented

        func dimension(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome, .windowNavigation:
                return MonknotMetrics.chromeButtonDimension(theme: theme, zoomScale: zoomScale)
            case .compact:
                return max(26, MonknotMetrics.interfaceControl(26, theme: theme, zoomScale: zoomScale))
            case .findBar:
                return max(24, MonknotMetrics.interfaceControl(24, theme: theme, zoomScale: zoomScale))
            case .segmented:
                return max(28, MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoomScale))
            }
        }

        func iconSize(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome, .windowNavigation:
                return MonknotMetrics.interfaceGlyph(
                    MonknotMetrics.iconPointSizeBase,
                    theme: theme,
                    zoomScale: zoomScale
                )
            case .compact, .findBar:
                return MonknotMetrics.interfaceGlyph(12, theme: theme, zoomScale: zoomScale)
            case .segmented:
                return MonknotMetrics.interfaceGlyph(11, theme: theme, zoomScale: zoomScale)
            }
        }

        func cornerRadius(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome, .windowNavigation:
                return theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale)
            case .compact, .findBar:
                return theme.chromeRadius(6, zoomScale: zoomScale)
            case .segmented:
                return theme.chromeRadius(5, zoomScale: zoomScale)
            }
        }

        func hoverBackgroundOpacity(isDark: Bool) -> Double {
            switch self {
            case .windowNavigation:
                return isDark ? 0.10 : 0.065
            case .chrome, .compact, .findBar, .segmented:
                return isDark ? 0.065 : 0.048
            }
        }

        func activeBackgroundOpacity(isDark: Bool) -> Double {
            isDark ? 0.12 : 0.08
        }

        func backgroundOpacity(isHovered: Bool, isDisabled: Bool, isDark: Bool) -> Double? {
            guard isHovered, !isDisabled else { return nil }
            return hoverBackgroundOpacity(isDark: isDark)
        }

        var disabledControlOpacity: Double {
            switch self {
            case .windowNavigation:
                return 0.72
            case .chrome, .compact, .findBar, .segmented:
                return 0.38
            }
        }

    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size.iconSize(theme: theme, zoomScale: zoomScale), weight: size == .findBar ? .semibold : .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(iconColor)
                .frame(width: size.dimension(theme: theme, zoomScale: zoomScale), height: size.dimension(theme: theme, zoomScale: zoomScale))
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
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: size.cornerRadius(theme: theme, zoomScale: zoomScale))
                            .strokeBorder(theme.accentColor.opacity(0.9), lineWidth: 1.5)
                            .padding(1)
                    } else if isActive, !isDisabled {
                        RoundedRectangle(cornerRadius: size.cornerRadius(theme: theme, zoomScale: zoomScale))
                            .strokeBorder(theme.borderColor, lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: size.cornerRadius(theme: theme, zoomScale: zoomScale)))
        }
        .buttonStyle(MonknotControlPressStyle())
        .disabled(isDisabled)
        .focusable(!isDisabled)
        .focused($isFocused)
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
