import Foundation

/// Shared, ephemeral options for document and workspace text search.
///
/// Search remains diacritic-insensitive in both case modes to preserve
/// Monknot's existing behavior. Whole-word matching treats Unicode letters,
/// numbers, marks, and connector punctuation as word characters.
public struct MonknotSearchOptions: Equatable, Sendable {
    public var isCaseSensitive: Bool
    public var isWholeWord: Bool

    public init(isCaseSensitive: Bool = false, isWholeWord: Bool = false) {
        self.isCaseSensitive = isCaseSensitive
        self.isWholeWord = isWholeWord
    }

    public var comparisonOptions: NSString.CompareOptions {
        var options: NSString.CompareOptions = [.diacriticInsensitive]
        if !isCaseSensitive {
            options.insert(.caseInsensitive)
        }
        return options
    }
}

public enum MonknotTextSearch {
    public static func matchingRanges(
        of query: String,
        in text: String,
        options: MonknotSearchOptions = MonknotSearchOptions()
    ) -> [NSRange] {
        let nsText = text as NSString
        guard !query.isEmpty, nsText.length > 0 else { return [] }

        var matches: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsText.length)

        while searchRange.length > 0 {
            let found = nsText.range(
                of: query,
                options: options.comparisonOptions,
                range: searchRange
            )
            guard found.location != NSNotFound, found.length > 0 else { break }

            let composedRange = nsText.rangeOfComposedCharacterSequences(for: found)
            if !options.isWholeWord || rangeIsWholeWord(composedRange, in: text) {
                matches.append(composedRange)
            }

            let nextLocation = NSMaxRange(composedRange)
            guard nextLocation < nsText.length else { break }
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }

        return matches
    }

    public static func rangeIsWholeWord(_ range: NSRange, in text: String) -> Bool {
        let nsText = text as NSString
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= nsText.length
        else { return false }

        if range.location > 0 {
            let previousRange = nsText.rangeOfComposedCharacterSequence(at: range.location - 1)
            if containsWordCharacter(nsText.substring(with: previousRange)) {
                return false
            }
        }

        let end = NSMaxRange(range)
        if end < nsText.length {
            let nextRange = nsText.rangeOfComposedCharacterSequence(at: end)
            if containsWordCharacter(nsText.substring(with: nextRange)) {
                return false
            }
        }

        return true
    }

    private static func containsWordCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter,
                 .lowercaseLetter,
                 .titlecaseLetter,
                 .modifierLetter,
                 .otherLetter,
                 .nonspacingMark,
                 .spacingMark,
                 .enclosingMark,
                 .decimalNumber,
                 .letterNumber,
                 .otherNumber,
                 .connectorPunctuation:
                return true
            default:
                return false
            }
        }
    }
}
