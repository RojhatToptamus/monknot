import AppKit
import MonknotCore
import XCTest

final class NativeUTF8TextTests: XCTestCase {
    func testTextStorageStringBecomesNativeWithIdenticalUTF16Content() {
        let source = "# Café — résumé\n\nLatência 😀 e\u{301}\n"
        let storage = NSTextStorage(string: source)
        storage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "x")
        let bridged = storage.string

        let native = NativeUTF8Text.copy(of: bridged)

        XCTAssertEqual(native.utf8.withContiguousStorageIfAvailable { _ in true }, true)
        XCTAssertEqual(Array(native.utf16), Array(bridged.utf16))
        XCTAssertEqual((native as NSString).length, storage.length)
    }

    func testNativeTextIsReturnedAsIs() {
        var native = String(repeating: "word ", count: 1_000)
        native.makeContiguousUTF8()

        let copy = NativeUTF8Text.copy(of: native)

        XCTAssertEqual(copy, native)
        XCTAssertEqual(copy.utf8.withContiguousStorageIfAvailable { $0.baseAddress }, native.utf8.withContiguousStorageIfAvailable { $0.baseAddress })
    }

    func testUnpairedSurrogateIsNeverRewritten() {
        let units: [unichar] = [0x0061, 0xD800, 0x0062]
        let lone = NSString(characters: units, length: units.count)

        XCTAssertNil(NativeUTF8Text.copy(of: lone))
        let result = NativeUTF8Text.copy(of: lone as String) as NSString
        XCTAssertEqual(result.length, units.count)
        XCTAssertEqual(result.character(at: 1), 0xD800)
    }

    func testEmptyTextRoundTrips() {
        XCTAssertEqual(NativeUTF8Text.copy(of: NSTextStorage(string: "").string), "")
    }
}
