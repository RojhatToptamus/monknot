import Foundation
import XCTest
@testable import MonknotCore

final class WorkspaceTreeExpansionPersistenceTests: XCTestCase {
    func testExpansionStateIsIndependentPerWorkspaceIncludingCollapsedAll() {
        let defaultsFixture = IsolatedUserDefaults(prefix: "WorkspaceTreeExpansionPersistenceTests")
        let persistence = WorkspaceTreeExpansionPersistence(
            defaults: defaultsFixture.userDefaults,
            keyPrefix: "tree"
        )
        let first = URL(fileURLWithPath: "/tmp/Monknot/A", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/Monknot/B", isDirectory: true)

        XCTAssertNil(persistence.load(for: first))
        persistence.save(["/tmp/Monknot/A/Notes"], for: first)
        persistence.save([], for: second)

        XCTAssertEqual(persistence.load(for: first), ["/tmp/Monknot/A/Notes"])
        XCTAssertEqual(persistence.load(for: second), [])
    }
}
