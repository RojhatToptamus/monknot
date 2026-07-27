import SwiftUI

enum MonknotMotion {
    static let hoverDuration: Double = 0.12
    static let chromeTransitionDuration: Double = 0.14
    static let sidebarTransitionDuration: Double = 0.22

    static var hoverAnimation: Animation {
        .easeOut(duration: hoverDuration)
    }

    static func sidebarTransition(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: 0.001)
            : .easeInOut(duration: sidebarTransitionDuration)
    }

    static func searchBarTransition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .opacity.combined(with: .scale(scale: 0.98, anchor: .trailing))
    }

    static func chromeTransition(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: 0.001)
            : .easeOut(duration: chromeTransitionDuration)
    }
}
