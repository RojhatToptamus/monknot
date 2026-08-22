import Foundation
import XCTest

final class RepositoryGovernanceContractTests: RepositoryContractTestCase {
    func testCodeOwnersRequiresRepositoryOwnerReviewForEveryChange() throws {
        let root = repositoryRoot
        let codeOwners = try String(
            contentsOf: root.appendingPathComponent(".github/CODEOWNERS"),
            encoding: .utf8
        )
        let rules = codeOwners
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") }

        XCTAssertEqual(rules, ["* @RojhatToptamus"])
    }
}
