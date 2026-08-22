import Foundation
import XCTest
@testable import MonknotCore

class FlowProtectedRangeTestCase: XCTestCase {
    let service = FlowProtectedRangeService()

    func protectedSubstrings(
        in text: String,
        mode: FlowSourceMode = .markdown
    ) -> [String] {
        let source = text as NSString
        return service.protectedRanges(in: text, mode: mode).map {
            source.substring(with: $0)
        }
    }
}
