import SwiftUI

enum MonknotMotion {
    static let hoverDuration: Double = 0.12
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
}
