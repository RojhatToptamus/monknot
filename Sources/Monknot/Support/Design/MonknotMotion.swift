import SwiftUI

enum MonknotMotion {
    static let hoverDuration: Double = 0.12
    static let chromeTransitionDuration: Double = 0.14

    static var hoverAnimation: Animation {
        .easeOut(duration: hoverDuration)
    }

    static var drawerSpring: Animation {
        .spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.08)
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
