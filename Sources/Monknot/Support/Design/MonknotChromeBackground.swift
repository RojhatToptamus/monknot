import MonknotCore
import SwiftUI

extension View {
    func monknotChromeBottomBorder(theme: AppTheme) -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.separatorColor)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    func monknotStableNavigationChrome() -> some View {
        if #available(macOS 26.0, *) {
            self
                .backgroundExtensionEffect(isEnabled: false)
                .scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}
