import AppKit
import MarkprevCore
import SwiftUI

extension Color {
    init(hex: String) {
        if let rgb = RGBHex(hex) {
            self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
        } else {
            self.init(nsColor: .labelColor)
        }
    }
}

extension NSColor {
    convenience init(hex: String) {
        if let rgb = RGBHex(hex) {
            self.init(calibratedRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
        } else {
            self.init(calibratedWhite: 1, alpha: 1)
        }
    }
}

extension AppTheme {
    private var normalizedContrast: Double {
        min(100, max(0, contrast)) / 100
    }

    var surfaceColor: Color {
        Color(hex: background)
    }

    var foregroundColor: Color {
        Color(hex: foreground)
    }

    var accentColor: Color {
        Color(hex: accent)
    }

    var borderColor: Color {
        foregroundColor.opacity((isDark ? 0.08 : 0.06) + normalizedContrast * 0.10)
    }

    var elevatedSurfaceColor: Color {
        foregroundColor.opacity((isDark ? 0.035 : 0.025) + normalizedContrast * 0.055)
    }

    var mutedForegroundColor: Color {
        foregroundColor.opacity((isDark ? 0.52 : 0.45) + normalizedContrast * 0.18)
    }

    var selectedRowColor: Color {
        accentColor.opacity(0.08 + normalizedContrast * 0.10)
    }

    func sidebarColor(_ color: Color, opacity: Double = 1) -> Color {
        color.opacity(opacity * (quietSidebar ? 0.8 : 1))
    }
}
