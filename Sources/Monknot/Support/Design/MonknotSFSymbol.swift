import AppKit

/// Resolves SF Symbol names against the running OS so glyphs never render as empty boxes.
enum MonknotSFSymbol {
    static func resolve(_ preferred: String, fallback: String) -> String {
        if NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil {
            return preferred
        }
        if NSImage(systemSymbolName: fallback, accessibilityDescription: nil) != nil {
            return fallback
        }
        return "doc"
    }
}
