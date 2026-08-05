import MonknotCore
import SwiftUI

struct MonknotKeyboardShortcutsHelpView: View {
    let theme: AppTheme
    let zoomScale: Double
    let close: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            VStack(alignment: .leading, spacing: scaled(12)) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: scaled(16), weight: .semibold))
                        .foregroundStyle(theme.foregroundColor)

                    Spacer(minLength: 0)

                    MonknotIconButton(
                        systemImage: "xmark",
                        label: "Close Shortcuts Help",
                        theme: theme,
                        zoomScale: zoomScale,
                        size: .compact,
                        action: close
                    )
                }

                MonknotScrollView {
                    LazyVStack(spacing: scaled(6)) {
                        ForEach(Array(MonknotKeyboardShortcutCatalog.entries.enumerated()), id: \.offset) { _, entry in
                            HStack(spacing: scaled(12)) {
                                Text(entry.title)
                                    .font(.system(size: scaled(13)))
                                    .foregroundStyle(theme.foregroundColor)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(entry.shortcut)
                                    .font(.system(size: scaled(12), weight: .medium, design: .rounded))
                                    .foregroundStyle(theme.mutedForegroundColor)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, scaled(10))
                            .padding(.vertical, scaled(6))
                            .background(
                                RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                                    .fill(theme.insetFillColor.opacity(0.55))
                            )
                        }
                    }
                }
                .frame(maxHeight: scaled(360))
            }
            .padding(scaled(16))
            .frame(width: scaled(460))
            .background(
                RoundedRectangle(cornerRadius: theme.chromeRadius(12, zoomScale: zoomScale))
                    .fill(theme.surfaceColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.chromeRadius(12, zoomScale: zoomScale))
                    .strokeBorder(theme.borderColor, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
    }
}
