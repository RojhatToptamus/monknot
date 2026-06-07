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
        case compact
        case findBar

        func dimension(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome:
                return MonknotMetrics.scale(MonknotMetrics.iconButtonSizeBase, theme: theme, zoomScale: zoomScale)
            case .compact:
                return MonknotMetrics.scale(24, theme: theme, zoomScale: zoomScale)
            case .findBar:
                return MonknotMetrics.scale(24, theme: theme, zoomScale: zoomScale)
            }
        }

        func iconSize(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome:
                return MonknotMetrics.scale(MonknotMetrics.iconPointSizeBase, theme: theme, zoomScale: zoomScale)
            case .compact, .findBar:
                return MonknotMetrics.scale(12, theme: theme, zoomScale: zoomScale)
            }
        }

        func cornerRadius(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome:
                return theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale)
            case .compact, .findBar:
                return theme.chromeRadius(6, zoomScale: zoomScale)
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
                .background(background, in: RoundedRectangle(cornerRadius: size.cornerRadius(theme: theme, zoomScale: zoomScale)))
                .contentShape(RoundedRectangle(cornerRadius: size.cornerRadius(theme: theme, zoomScale: zoomScale)))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .focusable(!isDisabled)
        .focused($isFocused)
        .opacity(isDisabled ? 0.4 : 1)
        .onHover { isHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .animation(MonknotMotion.hoverAnimation, value: isActive)
        .help(label)
        .accessibilityLabel(label)
        .monknotPointerCursor(enabled: !isDisabled)
    }

    private var background: Color {
        if isActive {
            return theme.controlTrackFillColor
        }
        if isHovered && !isDisabled {
            return theme.foregroundColor.opacity(theme.isDark ? 0.065 : 0.048)
        }
        return .clear
    }

    private var iconColor: Color {
        if isDisabled {
            return theme.mutedForegroundColor.opacity(0.42)
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
