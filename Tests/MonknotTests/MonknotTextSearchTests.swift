import Foundation
import XCTest
@testable import MonknotCore

final class MonknotTextSearchTests: XCTestCase {
    func testDefaultSearchIsCaseAndDiacriticInsensitive() {
        let text = "Résumé RESUME resume"

        let ranges = MonknotTextSearch.matchingRanges(of: "resume", in: text)

        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["Résumé", "RESUME", "resume"])
    }

    func testCaseSensitiveSearchStillUsesCanonicalDiacriticEquivalence() {
        let text = "résumé Resume RESUME resume"
        let options = MonknotSearchOptions(isCaseSensitive: true)

        let ranges = MonknotTextSearch.matchingRanges(of: "resume", in: text, options: options)

        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["résumé", "resume"])
    }

    func testWholeWordUsesUnicodeWordCharactersAtBothBoundaries() {
        let text = "cat scatter cat_2 cat-café 猫猫 猫"
        let options = MonknotSearchOptions(isWholeWord: true)

        let latin = MonknotTextSearch.matchingRanges(of: "cat", in: text, options: options)
        let cjk = MonknotTextSearch.matchingRanges(of: "猫", in: text, options: options)

        XCTAssertEqual(latin.map { (text as NSString).substring(with: $0) }, ["cat", "cat"])
        XCTAssertEqual(cjk.map { (text as NSString).substring(with: $0) }, ["猫"])
    }

    func testMatchingRangesPreserveOriginalUTF16RangeForDecomposedText() {
        let text = "Cafe\u{301} noir"

        let ranges = MonknotTextSearch.matchingRanges(of: "café", in: text)

        XCTAssertEqual(ranges, [NSRange(location: 0, length: 5)])
        XCTAssertEqual((text as NSString).substring(with: ranges[0]), "Cafe\u{301}")
    }
}
