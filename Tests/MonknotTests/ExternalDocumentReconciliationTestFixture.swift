import Foundation
import XCTest
@testable import MonknotCore

class ExternalDocumentReconciliationTestCase: XCTestCase {

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalDocumentReconciliationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
