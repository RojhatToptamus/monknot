import QuartzCore
import SwiftUI

enum MonknotMotion {
    static let hoverDuration: Double = 0.12
    static let outlineDuration: Double = 0.16
    /// Sidebar and terminal open and close with the standard macOS split-view transition.
    static let paneTransitionDuration: Double = 0.25
    /// The snapshot over the document fades into the laid-out document once a pane has moved.
    static let paneCoverFadeDuration: Double = 0.12
    static let terminalFullscreenTransitionDuration: Double = 0.18

    static var hoverAnimation: Animation {
        .easeOut(duration: hoverDuration)
    }

    /// The SwiftUI side of the pane transition, on the same ease-in-ease-out curve as AppKit's.
    static var paneTransition: Animation {
        .timingCurve(0.42, 0, 0.58, 1, duration: paneTransitionDuration)
    }

    static var paneTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(name: .easeInEaseOut)
    }

    /// Reduce Motion shows and hides panes instantly.
    static func paneTransition(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : paneTransition
    }

    static var terminalFullscreenTransition: Animation {
        .easeInOut(duration: terminalFullscreenTransitionDuration)
    }

    static func outlineAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion
            ? nil
            : .easeOut(duration: outlineDuration)
    }

    static func toastAnimation(reduceMotion: Bool) -> Animation {
        .easeOut(duration: reduceMotion ? 0.09 : 0.16)
    }

    static func toastTransition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .move(edge: .bottom).combined(with: .opacity)
    }
}
