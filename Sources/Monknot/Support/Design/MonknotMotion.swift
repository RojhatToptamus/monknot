import QuartzCore
import SwiftUI

/// Monknot's two timings (design.md §11): 120 ms ease-out for anything small that changes state or
/// comes and goes, and AppKit's 250 ms split-view transition for anything that moves a pane.
enum MonknotMotion {
    /// Hover, press, selection and focus fade their colour; a mark that comes and goes (a tab's
    /// close button, a focus ring, the outline's panel, a toast) fades; a disclosure chevron turns.
    static let hoverDuration: Double = 0.12
    /// Every pane movement is the standard macOS split-view transition: the sidebar and terminal
    /// opening and closing, and the terminal taking the full width and giving it back.
    static let paneTransitionDuration: Double = 0.25
    /// How far a surface that comes and goes on its own (a toast) rises as it appears.
    static let fadeUpDistance: CGFloat = 4

    static var hoverAnimation: Animation {
        .easeOut(duration: hoverDuration)
    }

    /// A state change that moves something rather than fading it (a disclosure chevron's quarter
    /// turn, the outline rail widening and scrolling to a heading): the hover timing, and none with
    /// Reduce Motion.
    static func stateMotion(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : hoverAnimation
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

    /// fadeUp: in from 4 pt below, and back out the same way; a plain fade with Reduce Motion.
    static func toastTransition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .offset(y: fadeUpDistance).combined(with: .opacity)
    }
}

extension View {
    /// Fades this view's ink, or a shape's fill, to `style` as a control's state changes (hovered,
    /// pressed, selected, focused) over the hover duration (design.md §11). Only the colour
    /// animates: a frame that changes in the same update, such as a row moving as its list lays
    /// out or a button moving with a pane, moves at once instead of sliding from where it was.
    func monknotStateStyle<Style: ShapeStyle>(_ style: Style) -> some View {
        animation(MonknotMotion.hoverAnimation) { $0.foregroundStyle(style) }
    }

    /// Fades this view in or out the same way, for a state mark that appears and disappears.
    func monknotStateOpacity(_ opacity: Double) -> some View {
        animation(MonknotMotion.hoverAnimation) { $0.opacity(opacity) }
    }
}
