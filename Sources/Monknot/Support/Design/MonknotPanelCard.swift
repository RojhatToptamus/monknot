import MonknotCore
import SwiftUI

/// Bordered card grouping used in settings, export sheets, and chrome panels.
struct MonknotPanelCard<Content: View>: View {
    let theme: AppTheme
    var usesSettingsRadii: Bool = true
    @ViewBuilder let content: () -> Content

    private var cornerRadius: CGFloat {
        usesSettingsRadii ? theme.settingsCardCornerRadius : theme.chromeRadius(10, zoomScale: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(theme.elevatedSurfaceColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(theme.borderColor, lineWidth: 1)
        )
    }
}

typealias SettingsGroupCard = MonknotPanelCard
