import AppKit
import MonknotCore

/// Whether macOS is light or dark. Each window adopts its theme's appearance, so a window's own
/// color scheme can't choose the System theme; the app's appearance follows macOS under System.
@MainActor
final class SystemAppearanceMonitor: ObservableObject {
    static let shared = SystemAppearanceMonitor()

    @Published private(set) var appearance: SystemAppearance
    private var observation: NSKeyValueObservation?

    private init() {
        appearance = Self.current
        observation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let appearance = Self.current
                if self.appearance != appearance { self.appearance = appearance }
            }
        }
    }

    private static var current: SystemAppearance {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

extension ThemePreference {
    /// The appearance the app adopts; nil follows macOS.
    var appAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }

    var systemImage: String {
        switch self {
        case .system:
            return "macwindow"
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        }
    }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}
