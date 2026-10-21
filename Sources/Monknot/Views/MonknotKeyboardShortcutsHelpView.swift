import MonknotCore
import SwiftUI

/// Help › Keyboard Shortcuts: the same overlay as Quick Open, with the shortcuts grouped under group
/// headers in 30 menu rows, each with its reference key cap (design.md §4.4).
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

                MonknotCommandOverlaySeparator(theme: theme)

                MonknotScrollView(theme: theme) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(MonknotKeyboardShortcutCatalog.sections.enumerated()), id: \.element.title) { index, section in
                            MonknotMenuGroupHeader(
                                title: section.title,
                                isFirst: index == 0,
                                leadingPaddingBase: MonknotMetrics.menuRowPaddingBase,
                                theme: theme,
                                zoomScale: zoomScale
                            )

                            VStack(spacing: MonknotCommandOverlayMetrics.rowGapBase) {
                                ForEach(section.entries, id: \.title) { entry in
                                    MonknotMenuRowLabel(
                                        leading: .none,
                                        title: entry.title,
                                        theme: theme,
                                        zoomScale: zoomScale
                                    ) {
                                        MonknotShortcutLabel(
                                            shortcut: entry.shortcut,
                                            theme: theme,
                                            zoomScale: zoomScale,
                                            presentation: .keyCap
                                        )
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                    .padding(scaled(MonknotMetrics.menuListInsetBase))
                }
            }
        }
    }
}
