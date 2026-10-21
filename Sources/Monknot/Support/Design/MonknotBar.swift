import MonknotCore
import SwiftUI

/// The titlebar row (design.md §10.1): 44 tall, its edges on the columns below it
/// (`MonknotMetrics.titlebarLeadingInset`, `titlebarTrailingInset`).
struct MonknotTitlebarRowLayout: ViewModifier {
    let theme: AppTheme
    let zoomScale: Double

    func body(content: Content) -> some View {
        content
            .padding(.leading, MonknotMetrics.titlebarLeadingInset(theme: theme, zoomScale: zoomScale))
            .padding(.trailing, MonknotMetrics.titlebarTrailingInset(theme: theme, zoomScale: zoomScale))
            .frame(
                height: MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale),
                alignment: .center
            )
            .frame(maxWidth: .infinity)
    }
}

extension View {
    func monknotTitlebarRowLayout(theme: AppTheme, zoomScale: Double) -> some View {
        modifier(MonknotTitlebarRowLayout(theme: theme, zoomScale: zoomScale))
    }
}

/// How far a bar's controls sit from its edges.
enum MonknotBarInset {
    /// 6, a card's bar: the terminal's header, the PDF toolbar, a banner.
    case bar
    /// The 10 list inset of the list below the bar, so its title or first glyph sits on the rows' glyph
    /// column and its last button ends on the list's edge: the sidebar header, Find in Workspace's and
    /// Links'.
    case list

    var base: CGFloat {
        switch self {
        case .bar: return MonknotMetrics.barPaddingBase
        case .list: return MonknotMetrics.listGutterBase
        }
    }
}

/// The one bar below the titlebar (design.md §10.6): 40 tall, 28 controls 2 apart, groups 8 apart
/// (`MonknotBarGroupGap`). It has no fill and no rule of its own: it sits on its card or panel, and
/// space alone groups its controls. The terminal's header, the PDF toolbar, a banner and the headers of
/// the sidebar, Find in Workspace and Links are this bar.
struct MonknotBar<Content: View>: View {
    let theme: AppTheme
    let zoomScale: Double
    var inset: MonknotBarInset = .bar
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: MonknotMetrics.interfaceDensity(MonknotMetrics.barItemGapBase, theme: theme, zoomScale: zoomScale)) {
            content()
        }
        .padding(.horizontal, MonknotMetrics.interfaceDensity(inset.base, theme: theme, zoomScale: zoomScale))
        .frame(height: MonknotMetrics.barHeight(theme: theme, zoomScale: zoomScale))
        .frame(maxWidth: .infinity)
    }
}

/// The space between two groups of a bar: with the bar's own 2 on either side, groups sit 8 apart. It
/// takes what the two item gaps leave of the group gap, each rounded once, so the groups land on one
/// rounding of 8 at every zoom (design.md §9.3).
struct MonknotBarGroupGap: View {
    let theme: AppTheme
    let zoomScale: Double

    static func width(theme: AppTheme, zoomScale: Double) -> CGFloat {
        MonknotMetrics.interfaceDensity(MonknotMetrics.barGroupGapBase, theme: theme, zoomScale: zoomScale)
            - 2 * MonknotMetrics.interfaceDensity(MonknotMetrics.barItemGapBase, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Color.clear
            .frame(width: Self.width(theme: theme, zoomScale: zoomScale), height: 1)
            .accessibilityHidden(true)
    }
}

/// A banner across the top of a card (design.md §13): the bar (40, 6 padding, no rule) on the elevated
/// surface, or on `dangersoft` when something is lost (a file removed on disk). Its glyph sits in the
/// 18 column, centred where a bar's first 28 button centres, then one 13 `ink` line and the banner's
/// 28 push buttons, 8 apart. The file-changed banner and the PDF markup hint are this banner.
struct MonknotBanner<Actions: View>: View {
    enum Tone {
        case neutral
        case danger
    }

    let systemImage: String
    let message: String
    var tone: Tone = .neutral
    let theme: AppTheme
    let zoomScale: Double
    @ViewBuilder let actions: () -> Actions

    private func density(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        MonknotBar(theme: theme, zoomScale: zoomScale) {
            HStack(spacing: density(MonknotMetrics.rowGlyphGapBase)) {
                MonknotFileKindGlyph(systemImage: systemImage, theme: theme, zoomScale: zoomScale)
                    .foregroundStyle(tone == .danger ? theme.dangerColor : theme.tertiaryForegroundColor)
                    .accessibilityHidden(true)

                Text(message)
                    .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.foregroundColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, density((MonknotMetrics.iconButtonSizeBase - MonknotMetrics.rowIconColumnWidthBase) / 2))

            MonknotBarGroupGap(theme: theme, zoomScale: zoomScale)

            HStack(spacing: density(MonknotMetrics.barGroupGapBase)) {
                actions()
            }
        }
        .background(tone == .danger ? theme.dangerSoftFillColor : theme.elevatedSurfaceColor)
    }
}

extension MonknotBanner where Actions == EmptyView {
    init(systemImage: String, message: String, tone: Tone = .neutral, theme: AppTheme, zoomScale: Double) {
        self.init(systemImage: systemImage, message: message, tone: tone, theme: theme, zoomScale: zoomScale) {
            EmptyView()
        }
    }
}
