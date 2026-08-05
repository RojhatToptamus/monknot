import SwiftUI

enum MonknotMotion {
    static let hoverDuration: Double = 0.12
    static let outlineDuration: Double = 0.16
    static let sidebarTransitionDuration: Double = 0.22

    static var hoverAnimation: Animation {
        .easeOut(duration: hoverDuration)
    }

    static var sidebarTransition: Animation {
        .timingCurve(
            0.77,
            0,
            0.175,
            1,
            duration: sidebarTransitionDuration
        )
    }

    static func sidebarTransition(reduceMotion: Bool) -> Animation? {
        reduceMotion
            ? nil
            : sidebarTransition
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
