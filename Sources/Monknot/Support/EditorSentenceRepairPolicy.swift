import Foundation

/// Validates an on-device model repair without encoding language vocabulary.
///
/// The model result is always presented for explicit review. This policy only
/// rejects structurally unsafe output and unrelated rewrites.
enum EditorFlowAIRepairValidator {
    private static let maximumEditCount = 12

    static func edits(
        originalSentence: String,
        candidateSentence: String
    ) -> [EditorFlowCorrectionEdit]? {
        let original = originalSentence as NSString
        let candidate = candidateSentence as NSString
        guard original.length > 0,
              candidate.length > 0,
              originalSentence != candidateSentence,
              candidate.length <= FlowSentenceRepairRequest.maximumSentenceUTF16Length,
              abs(candidate.length - original.length) <= max(32, original.length / 3),
              structuralTokens(in: originalSentence) == structuralTokens(in: candidateSentence),
              markdownDelimiterSignature(in: originalSentence)
                  == markdownDelimiterSignature(in: candidateSentence),
              enclosureSignature(in: originalSentence) == enclosureSignature(in: candidateSentence),
              symbolSignature(in: originalSentence) == symbolSignature(in: candidateSentence),
              normalizedEditDistanceIsBounded(
                  from: originalSentence,
                  to: candidateSentence
              ),
              let edits = differenceEdits(
                  originalSentence: originalSentence,
                  candidateSentence: candidateSentence
              ),
              !edits.isEmpty,
              edits.count <= maximumEditCount
        else { return nil }

        return edits
    }

    private static func wordRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, _ in
            ranges.append(NSRange(range, in: text))
        }
        return ranges
    }

    /// Uses exact words only as diff anchors. It does not classify or interpret them.
    private static func differenceEdits(
        originalSentence: String,
        candidateSentence: String
    ) -> [EditorFlowCorrectionEdit]? {
        let originalSource = originalSentence as NSString
        let candidateSource = candidateSentence as NSString
        let originalWordRanges = wordRanges(in: originalSentence)
        let candidateWordRanges = wordRanges(in: candidateSentence)
        let originalWords = originalWordRanges.map { originalSource.substring(with: $0) }
        let candidateWords = candidateWordRanges.map { candidateSource.substring(with: $0) }

        var lengths = Array(
            repeating: Array(repeating: 0, count: candidateWords.count + 1),
            count: originalWords.count + 1
        )
        for originalIndex in originalWords.indices.reversed() {
            for candidateIndex in candidateWords.indices.reversed() {
                if originalWords[originalIndex] == candidateWords[candidateIndex] {
                    lengths[originalIndex][candidateIndex] =
                        lengths[originalIndex + 1][candidateIndex + 1] + 1
                } else {
                    lengths[originalIndex][candidateIndex] = max(
                        lengths[originalIndex + 1][candidateIndex],
                        lengths[originalIndex][candidateIndex + 1]
                    )
                }
            }
        }

        var matches: [(original: Int, candidate: Int)] = []
        var originalIndex = 0
        var candidateIndex = 0
        while originalIndex < originalWords.count,
              candidateIndex < candidateWords.count {
            if originalWords[originalIndex] == candidateWords[candidateIndex] {
                matches.append((originalIndex, candidateIndex))
                originalIndex += 1
                candidateIndex += 1
            } else if lengths[originalIndex + 1][candidateIndex]
                        >= lengths[originalIndex][candidateIndex + 1] {
                originalIndex += 1
            } else {
                candidateIndex += 1
            }
        }

        func trimSharedNonlexicalEdges(
            original: NSRange,
            candidate: NSRange
        ) -> (original: NSRange, candidate: NSRange) {
            var original = original
            var candidate = candidate
            let lexical = CharacterSet.alphanumerics
            while original.length > 0, candidate.length > 0 {
                let originalCharacter = originalSource.rangeOfComposedCharacterSequence(
                    at: original.location
                )
                let candidateCharacter = candidateSource.rangeOfComposedCharacterSequence(
                    at: candidate.location
                )
                let originalText = originalSource.substring(with: originalCharacter)
                let candidateText = candidateSource.substring(with: candidateCharacter)
                guard originalText == candidateText,
                      originalText.rangeOfCharacter(from: lexical) == nil
                else { break }
                original.location += originalCharacter.length
                original.length -= originalCharacter.length
                candidate.location += candidateCharacter.length
                candidate.length -= candidateCharacter.length
            }
            while original.length > 0, candidate.length > 0 {
                let originalCharacter = originalSource.rangeOfComposedCharacterSequence(
                    at: NSMaxRange(original) - 1
                )
                let candidateCharacter = candidateSource.rangeOfComposedCharacterSequence(
                    at: NSMaxRange(candidate) - 1
                )
                let originalText = originalSource.substring(with: originalCharacter)
                let candidateText = candidateSource.substring(with: candidateCharacter)
                guard originalText == candidateText,
                      originalText.rangeOfCharacter(from: lexical) == nil
                else { break }
                original.length -= originalCharacter.length
                candidate.length -= candidateCharacter.length
            }
            return (original, candidate)
        }

        var pairedRanges: [(original: NSRange, candidate: NSRange)] = []
        var originalOffset = 0
        var candidateOffset = 0
        for match in matches {
            let originalAnchor = originalWordRanges[match.original]
            let candidateAnchor = candidateWordRanges[match.candidate]
            let gap = trimSharedNonlexicalEdges(
                original: NSRange(
                    location: originalOffset,
                    length: originalAnchor.location - originalOffset
                ),
                candidate: NSRange(
                    location: candidateOffset,
                    length: candidateAnchor.location - candidateOffset
                )
            )
            if originalSource.substring(with: gap.original)
                != candidateSource.substring(with: gap.candidate) {
                pairedRanges.append(gap)
            }
            originalOffset = NSMaxRange(originalAnchor)
            candidateOffset = NSMaxRange(candidateAnchor)
        }
        let finalGap = trimSharedNonlexicalEdges(
            original: NSRange(
                location: originalOffset,
                length: originalSource.length - originalOffset
            ),
            candidate: NSRange(
                location: candidateOffset,
                length: candidateSource.length - candidateOffset
            )
        )
        if originalSource.substring(with: finalGap.original)
            != candidateSource.substring(with: finalGap.candidate) {
            pairedRanges.append(finalGap)
        }
        guard !pairedRanges.isEmpty else { return nil }

        let edits = pairedRanges.map { pair in
            EditorFlowCorrectionEdit(
                range: pair.original,
                originalText: originalSource.substring(with: pair.original),
                replacementText: candidateSource.substring(with: pair.candidate),
                kind: .grammar
            )
        }
        let rebuilt = NSMutableString(string: originalSentence)
        for edit in edits.reversed() {
            rebuilt.replaceCharacters(in: edit.range, with: edit.replacementText)
        }
        return rebuilt as String == candidateSentence ? edits : nil
    }

    /// Preserves authored tokens whose shape identifies code, identifiers, or numbers.
    private static func structuralTokens(in text: String) -> [String] {
        var result: [String] = []
        var token = ""

        func appendToken() {
            guard !token.isEmpty else { return }
            let isStructural = token.contains(where: { $0.isNumber })
                || token.contains("_")
                || token.contains("-")
                || token.dropFirst().contains(where: { $0.isUppercase })
            if isStructural {
                result.append(token)
            }
            token.removeAll(keepingCapacity: true)
        }

        for character in text {
            if character.isLetter || character.isNumber || character == "_" || character == "-" {
                token.append(character)
            } else {
                appendToken()
            }
        }
        appendToken()
        return result
    }

    private static func markdownDelimiterSignature(in text: String) -> String {
        let delimiters = CharacterSet(charactersIn: "*_`~")
        return String(text.unicodeScalars.filter(delimiters.contains))
    }

    private static func enclosureSignature(in text: String) -> String {
        let enclosures = CharacterSet(charactersIn: "()[]{}\"“”«»‹›")
        return String(text.unicodeScalars.filter(enclosures.contains))
    }

    private static func symbolSignature(in text: String) -> [UnicodeScalar] {
        text.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                return true
            default:
                return false
            }
        }
    }

    private static func normalizedEditDistanceIsBounded(
        from original: String,
        to candidate: String
    ) -> Bool {
        let left = Array(normalizedText(original))
        let right = Array(normalizedText(candidate))
        guard !left.isEmpty, !right.isEmpty else { return false }
        let maximumLength = max(left.count, right.count)
        return editDistance(left, right) * 2 <= maximumLength
    }

    private static func normalizedText(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        ).filter { $0.isLetter || $0.isNumber }
    }

    private static func editDistance(
        _ left: [Character],
        _ right: [Character]
    ) -> Int {
        var previous = Array(0...right.count)
        for leftIndex in left.indices {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for rightIndex in right.indices {
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    previous[rightIndex] + (left[leftIndex] == right[rightIndex] ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[right.count]
    }
}
