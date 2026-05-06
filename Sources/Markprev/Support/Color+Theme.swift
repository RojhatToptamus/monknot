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
        foregroundColor.opacity(isDark ? 0.12 : 0.10)
    }

    var elevatedSurfaceColor: Color {
        foregroundColor.opacity(isDark ? 0.055 : 0.045)
    }

    var mutedForegroundColor: Color {
        foregroundColor.opacity(isDark ? 0.68 : 0.62)
    }
}
