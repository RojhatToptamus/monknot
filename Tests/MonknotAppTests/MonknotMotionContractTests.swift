import Foundation
import XCTest

/// A state change animates only what it changes (design.md §11). `.animation(_:value:)` animates
/// everything in its subtree that changes in the same update, frames included, so a row or button
/// that moves as its list or pane lays out would draw at its old place and slide back: the sidebar
/// chevron that jumped as its folder opened. Controls use `monknotStateStyle` and
/// `monknotStateOpacity`, or `.animation(_:body:)` for one property.
final class MonknotMotionContractTests: XCTestCase {
    /// Views whose value-keyed animation moves a frame on purpose, with why. None: the outline's
    /// panel, the last one, now floats beside its rail and only its own transition moves.
    private let allowed: [String: String] = [:]

    func testNoViewAnimatesItsWholeSubtreeWhenAStateChanges() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/Monknot")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relativePath = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            let source = try String(contentsOf: url, encoding: .utf8)
            checked += 1
            let count = Self.valueKeyedAnimations(in: source)
            if allowed[relativePath] != nil {
                XCTAssertEqual(count, 1, "\(relativePath) keeps its one allowed animation")
            } else {
                XCTAssertEqual(count, 0, "\(relativePath) animates a whole view on a state change")
            }
        }
        XCTAssertGreaterThan(checked, 50)
    }

    func testTheScannerFindsValueKeyedAnimationsAcrossLines() {
        XCTAssertEqual(Self.valueKeyedAnimations(in: ".animation(.easeOut, value: isHovered)"), 1)
        XCTAssertEqual(Self.valueKeyedAnimations(in: ".animation(\n    MonknotMotion.outlineAnimation(reduceMotion: x),\n    value: isExpanded\n)"), 1)
        XCTAssertEqual(Self.valueKeyedAnimations(in: ".animation(MonknotMotion.hoverAnimation) { $0.opacity(value) }"), 0)
        XCTAssertEqual(Self.valueKeyedAnimations(in: "TimelineView(.animation(minimumInterval: 1, paused: false))"), 0)
    }

    /// Counts `.animation(...)` calls whose arguments, up to the matching parenthesis, name `value:`.
    static func valueKeyedAnimations(in source: String) -> Int {
        var count = 0
        var searchStart = source.startIndex
        while let match = source.range(of: ".animation(", range: searchStart..<source.endIndex) {
            var depth = 1
            var index = match.upperBound
            while index < source.endIndex, depth > 0 {
                switch source[index] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                index = source.index(after: index)
            }
            if source[match.upperBound..<index].contains("value:") {
                count += 1
            }
            searchStart = match.upperBound
        }
        return count
    }
}
