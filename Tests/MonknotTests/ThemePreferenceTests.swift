import Foundation
import XCTest
@testable import MonknotCore

final class ThemePreferenceTests: MarkdownRenderServiceTestCase {
    func testNewUsersDefaultToHarborDarkWithoutReplacingSavedPreferences() {
        XCTAssertEqual(ThemePreference.defaultValue, .dark)
        XCTAssertEqual(ThemePreference.resolved(rawValue: nil), .dark)
        for savedPreference in ThemePreference.allCases {
            XCTAssertEqual(
                ThemePreference.resolved(rawValue: savedPreference.rawValue),
                savedPreference
            )
        }
        XCTAssertEqual(AppTheme.defaultDark.id, "harbor-dark")
    }
}
