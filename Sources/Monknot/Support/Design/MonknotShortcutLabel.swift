import MonknotCore
import SwiftUI

/// Shared presentation for standalone keyboard-shortcut metadata.
struct MonknotShortcutLabel: View {
    enum Presentation {
        case quietHint
        case keyCap
    }

    let shortcut: String
    let theme: AppTheme
    let zoomScale: Double
    var presentation: Presentation = .quietHint

    static let fontSizeBase: CGFloat = 12
    static let fontWeight: Font.Weight = .regular
    static let fontDesign: Font.Design = .rounded
    static let keyCapHorizontalPaddingBase: CGFloat = 9
    static let keyCapVerticalPaddingBase: CGFloat = 4
    static let keyCapRadiusBase: CGFloat = 6

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Text(shortcut)
            .font(.system(
                size: MonknotMetrics.interfaceText(
                    Self.fontSizeBase,
                    theme: theme,
                    zoomScale: zoomScale
                ),
                weight: Self.fontWeight,
                design: Self.fontDesign
            ))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                if presentation == .keyCap {
                    RoundedRectangle(cornerRadius: theme.chromeRadius(
                        Self.keyCapRadiusBase,
                        zoomScale: zoomScale
                    ))
                    .fill(theme.insetFillColor)
                }
            }
            .fixedSize()
    }

    private var foregroundColor: Color {
        switch presentation {
        case .quietHint:
            return theme.tertiaryForegroundColor
        case .keyCap:
            return theme.mutedForegroundColor
        }
    }

    private var horizontalPadding: CGFloat {
        presentation == .keyCap ? scaled(Self.keyCapHorizontalPaddingBase) : 0
    }

    private var verticalPadding: CGFloat {
        presentation == .keyCap ? scaled(Self.keyCapVerticalPaddingBase) : 0
    }
}
