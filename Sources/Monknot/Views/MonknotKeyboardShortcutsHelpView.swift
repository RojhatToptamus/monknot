import MonknotCore
import SwiftUI

/// Help › Keyboard Shortcuts: the same overlay as Quick Open, with the shortcuts grouped under eyebrow
/// headers in plain 30 rows, each with its reference key cap (design.md §4.4).
struct MonknotKeyboardShortcutsHelpView: View {
    let theme: AppTheme
    let zoomScale: Double
    let close: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        MonknotCommandOverlay(
            theme: theme,
            zoomScale: zoomScale,
            panelHeight: scaled(560),
            width: 480,
            close: close
        ) {
            VStack(spacing: 0) {
                MonknotCommandOverlayTitle(title: "Keyboard Shortcuts", theme: theme, zoomScale: zoomScale, close: close)

                Rectangle().fill(theme.separatorColor).frame(height: 1)

                MonknotScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(MonknotKeyboardShortcutCatalog.sections, id: \.title) { section in
                            Text(section.title)
                                .font(MonknotTypography.eyebrow(theme: theme, zoomScale: zoomScale))
                                .tracking(MonknotTypography.eyebrowTracking(theme: theme, zoomScale: zoomScale))
                                .textCase(.uppercase)
                                .foregroundStyle(theme.tertiaryForegroundColor)
                                .padding(.top, scaled(14))
                                .padding(.bottom, scaled(4))
                                .accessibilityAddTraits(.isHeader)

                            ForEach(section.entries, id: \.title) { entry in
                                HStack(spacing: scaled(12)) {
                                    Text(entry.title)
                                        .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                                        .foregroundStyle(theme.mutedForegroundColor)
                                        .lineLimit(1)

                                    Spacer(minLength: 0)

                                    MonknotShortcutLabel(
                                        shortcut: entry.shortcut,
                                        theme: theme,
                                        zoomScale: zoomScale,
                                        presentation: .keyCap
                                    )
                                }
                                .frame(height: scaled(30))
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    .padding(.horizontal, scaled(16))
                    .padding(.bottom, scaled(12))
                }
            }
        }
    }
}
