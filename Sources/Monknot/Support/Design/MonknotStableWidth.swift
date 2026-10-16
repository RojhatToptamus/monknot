import SwiftUI

/// Width templates for values that change in place. A slot laid out as wide as its widest value
/// never moves its neighbours when the value changes. Pair each template with monospaced digits.
enum MonknotStableWidth {
    /// As wide as any `count`-digit number in monospaced digits.
    static func digits(_ count: Int) -> String {
        String(repeating: "0", count: max(1, count))
    }

    /// As wide as any "page/pageCount" label of a document with `pageCount` pages.
    static func pageTemplate(pageCount: Int) -> String {
        let number = lineNumberTemplate(maximumLine: pageCount)
        return "\(number)/\(number)"
    }

    /// As wide as any line number up to `maximumLine`.
    static func lineNumberTemplate(maximumLine: Int) -> String {
        digits(String(abs(maximumLine)).count)
    }
}

extension View {
    /// Lays the view out at least as wide as the widest of `templates`, aligned by `alignment`.
    /// Apply font modifiers after this one, so the templates measure in the same font.
    func monknotReservingWidth(of templates: [String], alignment: Alignment = .trailing) -> some View {
        ZStack(alignment: alignment) {
            ForEach(Array(templates.enumerated()), id: \.offset) { _, template in
                Text(verbatim: template)
                    .hidden()
                    .accessibilityHidden(true)
            }
            self
        }
    }

    func monknotReservingWidth(of template: String, alignment: Alignment = .trailing) -> some View {
        monknotReservingWidth(of: [template], alignment: alignment)
    }
}
