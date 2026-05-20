import MonknotCore
import SwiftUI

private struct MonknotReduceTransparencyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var monknotReduceTransparency: Bool {
        get { self[MonknotReduceTransparencyKey.self] }
        set { self[MonknotReduceTransparencyKey.self] = newValue }
    }
}

struct MonknotChromeSurfaceReader<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.monknotReduceTransparency, reduceTransparency)
    }
}

extension View {
    func monknotChromeBottomBorder(theme: AppTheme) -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.separatorColor)
                .frame(height: 1)
        }
    }
}

enum MonknotChromeSurfaceStyleResolver {
    static func effective(
        requested: MonknotChromeSurfaceStyle,
        reduceTransparency: Bool
    ) -> MonknotChromeSurfaceStyle {
        guard !reduceTransparency else {
            return .solid
        }
        return requested
    }

    static var isLiquidGlassAvailable: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }
}
