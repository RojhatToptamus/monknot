import AppKit

/// Resolves SF Symbol names against the running OS so glyphs never render as empty boxes.
enum MonknotSFSymbol {
    /// Rows and tabs resolve their glyph on every render; availability never changes while the app runs.
    private static let resolved = NSCache<NSString, NSString>()

    static func resolve(_ preferred: String, fallback: String) -> String {
        let key = "\(preferred)\u{0}\(fallback)" as NSString
        if let cached = resolved.object(forKey: key) {
            return cached as String
        }
        let name: String
        if NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil {
            name = preferred
        } else if NSImage(systemSymbolName: fallback, accessibilityDescription: nil) != nil {
            name = fallback
        } else {
            name = "doc"
        }
        resolved.setObject(name as NSString, forKey: key)
        return name
    }
}
