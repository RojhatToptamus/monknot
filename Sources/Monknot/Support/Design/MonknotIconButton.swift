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

        func dimension(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome, .windowNavigation:
                return MonknotMetrics.chromeButtonDimension(theme: theme, zoomScale: zoomScale)
            case .compact:
                return MonknotMetrics.scale(24, theme: theme, zoomScale: zoomScale)
            case .findBar:
                return MonknotMetrics.scale(24, theme: theme, zoomScale: zoomScale)
            }
        }

        func iconSize(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome, .windowNavigation:
                return MonknotMetrics.scale(MonknotMetrics.iconPointSizeBase, theme: theme, zoomScale: zoomScale)
            case .compact, .findBar:
                return MonknotMetrics.scale(12, theme: theme, zoomScale: zoomScale)
            }
        }

        func cornerRadius(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome, .windowNavigation:
                return theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale)
            case .compact, .findBar:
                return theme.chromeRadius(6, zoomScale: zoomScale)
            }
        }

        func hoverBackgroundOpacity(isDark: Bool) -> Double {
            switch self {
            case .windowNavigation:
                return isDark ? 0.10 : 0.065
            case .chrome, .compact, .findBar:
                return isDark ? 0.065 : 0.048
            }
        }

        func backgroundOpacity(isHovered: Bool, isDisabled: Bool, isDark: Bool) -> Double? {
            guard isHovered, !isDisabled else { return nil }
            return hoverBackgroundOpacity(isDark: isDark)
        }

        var disabledControlOpacity: Double {
            switch self {
            case .windowNavigation:
                return 0.72
            case .chrome, .compact, .findBar:
                return 0.4
            }
        }

        var disabledIconOpacity: Double {
            switch self {
            case .windowNavigation:
                return 1
            case .chrome, .compact, .findBar:
                return 0.42
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
                    if let opacity = size.backgroundOpacity(
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
        .buttonStyle(.plain)
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
            return theme.mutedForegroundColor.opacity(size.disabledIconOpacity)
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
