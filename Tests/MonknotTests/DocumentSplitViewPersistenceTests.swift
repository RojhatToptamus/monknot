import XCTest
@testable import MonknotCore

final class DocumentSplitViewPersistenceTests: XCTestCase {
    func testStorageKeyUsesStablePathHash() {
        let path = "/tmp/workspace/notes/todo.md"
        let key = DocumentSplitViewPersistence.storageKey(forDocumentPath: path)
        XCTAssertTrue(key.hasPrefix("Monknot.markdownSplitView."))
        XCTAssertEqual(
            DocumentSplitViewPersistence.pathHash(path),
            DocumentSplitViewPersistence.pathHash(path + "/")
        )
    }

    func testPerDocumentSplitViewPersistence() {
        let defaultsFixture = IsolatedUserDefaults(prefix: "DocumentSplitViewPersistenceTests")
        let defaults = defaultsFixture.userDefaults

        let first = "/tmp/first.md"
        let second = "/tmp/second.md"

        DocumentSplitViewPersistence.setEnabled(true, forDocumentPath: first, defaults: defaults)
        DocumentSplitViewPersistence.setEnabled(false, forDocumentPath: second, defaults: defaults)

        XCTAssertTrue(DocumentSplitViewPersistence.isEnabled(forDocumentPath: first, defaults: defaults))
        XCTAssertFalse(DocumentSplitViewPersistence.isEnabled(forDocumentPath: second, defaults: defaults))
    }

    func testDefaultSplitValuesDoNotCreatePerDocumentKeys() {
        let defaultsFixture = IsolatedUserDefaults(prefix: "DocumentSplitViewPersistenceTests")
        let defaults = defaultsFixture.userDefaults

        let path = "/tmp/default.md"
        DocumentSplitViewPersistence.setEnabled(false, forDocumentPath: path, defaults: defaults)
        DocumentSplitViewPersistence.setSourcePaneRatio(
            DocumentSplitViewPersistence.defaultSourcePaneRatio,
            forDocumentPath: path,
            defaults: defaults
        )

        XCTAssertNil(defaults.object(forKey: DocumentSplitViewPersistence.storageKey(forDocumentPath: path)))
        XCTAssertNil(defaults.object(forKey: DocumentSplitViewPersistence.ratioStorageKey(forDocumentPath: path)))
    }

    func testSplitViewStoresOverrideWhenLegacyDefaultDiffers() {
        let defaultsFixture = IsolatedUserDefaults(prefix: "DocumentSplitViewPersistenceTests")
        let defaults = defaultsFixture.userDefaults

        let path = "/tmp/override.md"
        defaults.set(true, forKey: "Monknot.markdownSplitView")

        DocumentSplitViewPersistence.setEnabled(false, forDocumentPath: path, defaults: defaults)

        XCTAssertNotNil(defaults.object(forKey: DocumentSplitViewPersistence.storageKey(forDocumentPath: path)))
        XCTAssertFalse(DocumentSplitViewPersistence.isEnabled(forDocumentPath: path, defaults: defaults))
    }

    func testFallsBackToLegacyGlobalSplitViewPreference() {
        let defaultsFixture = IsolatedUserDefaults(prefix: "DocumentSplitViewPersistenceTests")
        let defaults = defaultsFixture.userDefaults

        defaults.set(true, forKey: "Monknot.markdownSplitView")
        XCTAssertTrue(DocumentSplitViewPersistence.isEnabled(forDocumentPath: "/tmp/new.md", defaults: defaults))
    }

    func testRemapDocumentPathMigratesSplitViewPreference() {
        let defaultsFixture = IsolatedUserDefaults(prefix: "DocumentSplitViewPersistenceTests")
        let defaults = defaultsFixture.userDefaults

        let source = "/tmp/workspace/old-name.md"
        let destination = "/tmp/workspace/new-name.md"

        DocumentSplitViewPersistence.setEnabled(true, forDocumentPath: source, defaults: defaults)
        DocumentSplitViewPersistence.remapDocumentPath(from: source, to: destination, defaults: defaults)

        XCTAssertNil(defaults.object(forKey: DocumentSplitViewPersistence.storageKey(forDocumentPath: source)))
        XCTAssertTrue(DocumentSplitViewPersistence.isEnabled(forDocumentPath: destination, defaults: defaults))
    }

    func testRemapDocumentPathNoOpWhenSourceHasNoStoredPreference() {
        let defaultsFixture = IsolatedUserDefaults(prefix: "DocumentSplitViewPersistenceTests")
        let defaults = defaultsFixture.userDefaults

        DocumentSplitViewPersistence.setEnabled(false, forDocumentPath: "/tmp/other.md", defaults: defaults)
        DocumentSplitViewPersistence.remapDocumentPath(
            from: "/tmp/missing.md",
            to: "/tmp/renamed.md",
            defaults: defaults
        )

        XCTAssertNil(defaults.object(forKey: DocumentSplitViewPersistence.storageKey(forDocumentPath: "/tmp/renamed.md")))
        XCTAssertNil(defaults.object(forKey: DocumentSplitViewPersistence.ratioStorageKey(forDocumentPath: "/tmp/renamed.md")))
    }

    func testPerDocumentSplitRatioPersistence() {
        let defaultsFixture = IsolatedUserDefaults(prefix: "DocumentSplitViewPersistenceTests")
        let defaults = defaultsFixture.userDefaults

        let first = "/tmp/first.md"
        let second = "/tmp/second.md"

        DocumentSplitViewPersistence.setSourcePaneRatio(0.62, forDocumentPath: first, defaults: defaults)
        DocumentSplitViewPersistence.setSourcePaneRatio(0.33, forDocumentPath: second, defaults: defaults)

        XCTAssertEqual(DocumentSplitViewPersistence.sourcePaneRatio(forDocumentPath: first, defaults: defaults), 0.62, accuracy: 0.001)
        XCTAssertEqual(DocumentSplitViewPersistence.sourcePaneRatio(forDocumentPath: second, defaults: defaults), 0.33, accuracy: 0.001)
    }

    func testSplitRatioClampsToSupportedRange() {
        XCTAssertEqual(DocumentSplitViewPersistence.clampedSourcePaneRatio(0.1), DocumentSplitViewPersistence.minSourcePaneRatio, accuracy: 0.001)
        XCTAssertEqual(DocumentSplitViewPersistence.clampedSourcePaneRatio(0.95), DocumentSplitViewPersistence.maxSourcePaneRatio, accuracy: 0.001)
    }

    func testRemapDocumentPathMigratesSplitRatioPreference() {
        let defaultsFixture = IsolatedUserDefaults(prefix: "DocumentSplitViewPersistenceTests")
        let defaults = defaultsFixture.userDefaults

        let source = "/tmp/workspace/old-name.md"
        let destination = "/tmp/workspace/new-name.md"

        DocumentSplitViewPersistence.setSourcePaneRatio(0.58, forDocumentPath: source, defaults: defaults)
        DocumentSplitViewPersistence.remapDocumentPath(from: source, to: destination, defaults: defaults)

        XCTAssertNil(defaults.object(forKey: DocumentSplitViewPersistence.ratioStorageKey(forDocumentPath: source)))
        XCTAssertEqual(
            DocumentSplitViewPersistence.sourcePaneRatio(forDocumentPath: destination, defaults: defaults),
            0.58,
            accuracy: 0.001
        )
    }
}
