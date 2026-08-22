import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

@MainActor
final class ContentWidthPreferenceTests: XCTestCase {
    func testLegacyPreviewWidthMigratesToTheContentWidthOwner() throws {
        let suiteName = "MonknotTests.ContentWidthMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(74.0, forKey: ContentWidthPreference.legacyPreviewWidthKey)

        XCTAssertEqual(ContentWidthPreference.initialValue(in: defaults), 74)
        XCTAssertEqual(defaults.double(forKey: ContentWidthPreference.key), 74)
        XCTAssertNil(defaults.object(forKey: ContentWidthPreference.legacyPreviewWidthKey))
    }

    func testExistingContentWidthWinsOverTheLegacyValue() throws {
        let suiteName = "MonknotTests.ContentWidthOwner.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(93.0, forKey: ContentWidthPreference.key)
        defaults.set(61.0, forKey: ContentWidthPreference.legacyPreviewWidthKey)

        XCTAssertEqual(ContentWidthPreference.initialValue(in: defaults), 93)
        XCTAssertEqual(defaults.double(forKey: ContentWidthPreference.key), 93)
        XCTAssertNil(defaults.object(forKey: ContentWidthPreference.legacyPreviewWidthKey))
    }

    func testRepeatedInitialValueReadsDoNotNotifyOrMutateValidCurrentDefaults() throws {
        let suiteName = "MonknotTests.ContentWidthSteadyState.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(82.0, forKey: ContentWidthPreference.key)
        let domainBeforeReads = defaults.persistentDomain(forName: suiteName) ?? [:]
        let recorder = UserDefaultsChangeRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { _ in
            recorder.recordChange()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        for _ in 0..<100 {
            XCTAssertEqual(ContentWidthPreference.initialValue(in: defaults), 82)
        }

        let domainAfterReads = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(recorder.changeCount, 0)
        XCTAssertTrue(
            NSDictionary(dictionary: domainBeforeReads).isEqual(to: domainAfterReads),
            "Reading a valid current preference must not mutate UserDefaults"
        )
    }

    func testLegacyMigrationChangesDefaultsOnceThenRepeatedReadsAreSilent() throws {
        let suiteName = "MonknotTests.ContentWidthOneTimeMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(74.0, forKey: ContentWidthPreference.legacyPreviewWidthKey)
        let recorder = UserDefaultsChangeRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { _ in
            recorder.recordChange()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertEqual(ContentWidthPreference.initialValue(in: defaults), 74)
        XCTAssertEqual(defaults.double(forKey: ContentWidthPreference.key), 74)
        XCTAssertNil(defaults.object(forKey: ContentWidthPreference.legacyPreviewWidthKey))
        let notificationCountAfterMigration = recorder.changeCount
        let domainAfterMigration = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertGreaterThan(notificationCountAfterMigration, 0)

        for _ in 0..<100 {
            XCTAssertEqual(ContentWidthPreference.initialValue(in: defaults), 74)
        }

        let domainAfterRepeatedReads = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(recorder.changeCount, notificationCountAfterMigration)
        XCTAssertTrue(
            NSDictionary(dictionary: domainAfterMigration).isEqual(to: domainAfterRepeatedReads),
            "The legacy value must migrate once; later reads must be mutation-free"
        )
    }

    func testEditableTextUsesAndReflowsWithContentWidth() {
        var text = "# Content width"
        var sourceLocation: MarkdownSourceLocation?
        var searchState = DocumentSearchState()
        let editor = MarkdownTextEditor(
            documentID: "/README.md",
            text: Binding(get: { text }, set: { text = $0 }),
            theme: .defaultDark,
            fontSize: 14,
            zoomScale: 1,
            contentWidthPercent: 80,
            fontSmoothing: true,
            scrollPosition: nil,
            sourceLocation: Binding(get: { sourceLocation }, set: { sourceLocation = $0 }),
            searchState: Binding(get: { searchState }, set: { searchState = $0 }),
            onScrollPositionChange: { _ in }
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            window.contentView = nil
        }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        guard let textView = host.descendantsForContentWidthTesting()
            .compactMap({ $0 as? NSTextView })
            .first else {
            return XCTFail("Missing mounted text editor")
        }

        XCTAssertEqual(
            textView.textContainerInset.width,
            ContentWidthPreference.editorHorizontalInset(
                viewportWidth: textView.bounds.width,
                contentWidthPercent: 80,
                zoomScale: 1
            ),
            accuracy: 0.5
        )
        XCTAssertEqual(
            textView.bounds.width - 2 * textView.textContainerInset.width,
            textView.bounds.width * 0.8,
            accuracy: 0.5,
            "The setting must describe the editable content column, not its margin"
        )
        let wideInset = textView.textContainerInset.width

        host.frame.size.width = 600
        window.setContentSize(NSSize(width: 600, height: 600))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            textView.textContainerInset.width,
            ContentWidthPreference.editorHorizontalInset(
                viewportWidth: textView.bounds.width,
                contentWidthPercent: 80,
                zoomScale: 1
            ),
            accuracy: 0.5
        )
        XCTAssertLessThan(textView.textContainerInset.width, wideInset)

        let insetBeforePreferenceChange = textView.textContainerInset.width
        host.rootView = MarkdownTextEditor(
            documentID: "/README.md",
            text: Binding(get: { text }, set: { text = $0 }),
            theme: .defaultDark,
            fontSize: 14,
            zoomScale: 1,
            contentWidthPercent: 60,
            fontSmoothing: true,
            scrollPosition: nil,
            sourceLocation: Binding(get: { sourceLocation }, set: { sourceLocation = $0 }),
            searchState: Binding(get: { searchState }, set: { searchState = $0 }),
            onScrollPositionChange: { _ in }
        )
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let updatedTextView = host.descendantsForContentWidthTesting()
            .compactMap { $0 as? NSTextView }
            .first
        XCTAssertTrue(updatedTextView === textView)
        XCTAssertEqual(
            textView.textContainerInset.width,
            ContentWidthPreference.editorHorizontalInset(
                viewportWidth: textView.bounds.width,
                contentWidthPercent: 60,
                zoomScale: 1
            ),
            accuracy: 0.5
        )
        XCTAssertGreaterThan(textView.textContainerInset.width, insetBeforePreferenceChange)
    }

    func testEditableContentGeometryReflowsAtWorkspaceZoomExtremes() {
        var text = "Zoom-aware editable content"
        var sourceLocation: MarkdownSourceLocation?
        var searchState = DocumentSearchState()

        func editor(zoomScale: Double) -> MarkdownTextEditor {
            MarkdownTextEditor(
                documentID: "/zoom.md",
                text: Binding(get: { text }, set: { text = $0 }),
                theme: .defaultDark,
                fontSize: 13 * WorkspaceZoomPolicy.documentScale(zoomScale),
                zoomScale: zoomScale,
                contentWidthPercent: 100,
                fontSmoothing: true,
                scrollPosition: nil,
                sourceLocation: Binding(get: { sourceLocation }, set: { sourceLocation = $0 }),
                searchState: Binding(get: { searchState }, set: { searchState = $0 }),
                onScrollPositionChange: { _ in }
            )
        }

        let host = NSHostingView(rootView: editor(zoomScale: WorkspaceZoomPolicy.minimum))
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 300)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            window.contentView = nil
        }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        guard let textView = host.descendantsForContentWidthTesting()
            .compactMap({ $0 as? NSTextView })
            .first,
            let textContainer = textView.textContainer else {
            return XCTFail("Missing mounted text editor")
        }

        XCTAssertEqual(
            textView.textContainerInset.width,
            ContentWidthPreference.editorHorizontalInset(
                viewportWidth: textView.bounds.width,
                contentWidthPercent: 100,
                zoomScale: WorkspaceZoomPolicy.minimum
            ),
            accuracy: 0.5
        )
        XCTAssertEqual(
            textView.textContainerInset.height,
            ContentWidthPreference.editorVerticalInset(zoomScale: WorkspaceZoomPolicy.minimum),
            accuracy: 0.5
        )
        XCTAssertEqual(
            textContainer.lineFragmentPadding,
            ContentWidthPreference.editorLineFragmentPadding(zoomScale: WorkspaceZoomPolicy.minimum),
            accuracy: 0.5
        )
        let compactInsets = textView.textContainerInset

        host.rootView = editor(zoomScale: WorkspaceZoomPolicy.maximum)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let updatedTextView = host.descendantsForContentWidthTesting()
            .compactMap { $0 as? NSTextView }
            .first
        XCTAssertTrue(updatedTextView === textView)
        XCTAssertEqual(
            textView.textContainerInset.width,
            ContentWidthPreference.editorHorizontalInset(
                viewportWidth: textView.bounds.width,
                contentWidthPercent: 100,
                zoomScale: WorkspaceZoomPolicy.maximum
            ),
            accuracy: 0.5
        )
        XCTAssertEqual(
            textView.textContainerInset.height,
            ContentWidthPreference.editorVerticalInset(zoomScale: WorkspaceZoomPolicy.maximum),
            accuracy: 0.5
        )
        XCTAssertEqual(
            textContainer.lineFragmentPadding,
            ContentWidthPreference.editorLineFragmentPadding(zoomScale: WorkspaceZoomPolicy.maximum),
            accuracy: 0.5
        )
        XCTAssertGreaterThan(textView.textContainerInset.width, compactInsets.width)
        XCTAssertGreaterThan(textView.textContainerInset.height, compactInsets.height)
    }

    func testEditorPlaceholderGeometryUsesTheSameZoomExtremes() {
        let viewportWidth: CGFloat = 120

        XCTAssertEqual(
            ContentWidthPreference.editorPlaceholderLeadingInset(
                viewportWidth: viewportWidth,
                contentWidthPercent: 100,
                zoomScale: 1
            ),
            28,
            "The established 100% placeholder alignment must not move"
        )
        XCTAssertEqual(ContentWidthPreference.editorVerticalInset(zoomScale: 1), 18)
        XCTAssertEqual(ContentWidthPreference.editorLineFragmentPadding(zoomScale: 1), 5)
        XCTAssertEqual(ContentWidthPreference.editorPlaceholderTopInset(zoomScale: 1), 26)
        XCTAssertEqual(ContentWidthPreference.editorPlaceholderMinimumFontSize(zoomScale: 1), 13)

        XCTAssertEqual(
            ContentWidthPreference.editorPlaceholderLeadingInset(
                viewportWidth: viewportWidth,
                contentWidthPercent: 100,
                zoomScale: WorkspaceZoomPolicy.minimum
            ),
            23
        )
        XCTAssertEqual(
            ContentWidthPreference.editorPlaceholderTopInset(
                zoomScale: WorkspaceZoomPolicy.minimum
            ),
            21
        )
        XCTAssertEqual(
            ContentWidthPreference.editorPlaceholderMinimumFontSize(
                zoomScale: WorkspaceZoomPolicy.minimum
            ),
            10.5
        )
        XCTAssertEqual(
            ContentWidthPreference.editorPlaceholderLeadingInset(
                viewportWidth: viewportWidth,
                contentWidthPercent: 100,
                zoomScale: WorkspaceZoomPolicy.maximum
            ),
            56
        )
        XCTAssertEqual(
            ContentWidthPreference.editorPlaceholderTopInset(
                zoomScale: WorkspaceZoomPolicy.maximum
            ),
            52
        )
        XCTAssertEqual(
            ContentWidthPreference.editorPlaceholderMinimumFontSize(
                zoomScale: WorkspaceZoomPolicy.maximum
            ),
            26
        )
    }

    func testRenderedHTMLInstallsTheContentWidthConstraint() {
        let script = HTMLPreviewView.Coordinator.previewBehaviorScript.source

        XCTAssertTrue(script.contains("monknotHTMLApplyContentWidth"))
        XCTAssertTrue(script.contains("--monknot-content-max-width"))
        XCTAssertTrue(script.contains("max-width: var(--monknot-content-max-width, 100%)"))
    }

    func testRenderedHTMLUpdatesItsMeasuredContentWidthWithoutReloading() async throws {
        var searchState = DocumentSearchState()
        func preview(contentWidthPercent: Double) -> HTMLPreviewView {
            HTMLPreviewView(
                documentID: "/page.html",
                html: "<html><body><main>Rendered content</main></body></html>",
                baseURL: nil,
                theme: .defaultDark,
                zoomScale: 1,
                contentWidthPercent: contentWidthPercent,
                scrollPosition: nil,
                syncScrollEnabled: false,
                syncScrollTargetLine: nil,
                sourceLineCount: 1,
                searchState: Binding(
                    get: { searchState },
                    set: { searchState = $0 }
                ),
                onScrollPositionChange: { _ in },
                onVisibleSourceLineChange: nil
            )
        }

        let host = NSHostingView(rootView: preview(contentWidthPercent: 80))
        host.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            window.contentView = nil
        }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        let webView = try XCTUnwrap(
            host.descendantsForContentWidthTesting().compactMap { $0 as? WKWebView }.first
        )

        let initialMetrics = try await waitForRenderedHTMLContentWidth(
            80,
            in: webView
        )
        XCTAssertEqual(initialMetrics.bodyToViewportRatio, 0.8, accuracy: 0.03)

        host.rootView = preview(contentWidthPercent: 60)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        let updatedWebView = try XCTUnwrap(
            host.descendantsForContentWidthTesting().compactMap { $0 as? WKWebView }.first
        )
        XCTAssertTrue(updatedWebView === webView)

        let updatedMetrics = try await waitForRenderedHTMLContentWidth(
            60,
            in: webView
        )
        XCTAssertEqual(updatedMetrics.bodyToViewportRatio, 0.6, accuracy: 0.03)
        XCTAssertLessThan(updatedMetrics.bodyWidth, initialMetrics.bodyWidth)
    }

    private func waitForRenderedHTMLContentWidth(
        _ percent: Double,
        in webView: WKWebView
    ) async throws -> RenderedHTMLContentMetrics {
        let expectedVariable = String(format: "%.0f%%", percent)
        var lastMetrics: RenderedHTMLContentMetrics?

        for _ in 0..<50 {
            if let result = evaluateJavaScript(
                """
                (() => ({
                  variable: getComputedStyle(document.documentElement)
                    .getPropertyValue('--monknot-content-max-width').trim(),
                  bodyWidth: document.body ? document.body.getBoundingClientRect().width : 0,
                  viewportWidth: document.documentElement.clientWidth || 0
                }))()
                """,
                in: webView
            ), let values = result as? [String: Any] {
                let metrics = RenderedHTMLContentMetrics(
                    variable: values["variable"] as? String ?? "",
                    bodyWidth: (values["bodyWidth"] as? NSNumber)?.doubleValue ?? 0,
                    viewportWidth: (values["viewportWidth"] as? NSNumber)?.doubleValue ?? 0
                )
                lastMetrics = metrics
                if metrics.variable == expectedVariable,
                   metrics.bodyWidth > 0,
                   metrics.viewportWidth > 0 {
                    return metrics
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTFail("Rendered HTML did not apply content width \(expectedVariable); last metrics: \(String(describing: lastMetrics))")
        return try XCTUnwrap(lastMetrics)
    }

    private func evaluateJavaScript(
        _ script: String,
        in webView: WKWebView,
        timeout: TimeInterval = 0.1
    ) -> Any? {
        var result: Any?
        var isComplete = false
        webView.evaluateJavaScript(script) { value, _ in
            result = value
            isComplete = true
        }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while !isComplete, Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
        return isComplete ? result : nil
    }
}

private final class UserDefaultsChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedChangeCount = 0

    var changeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedChangeCount
    }

    func recordChange() {
        lock.lock()
        storedChangeCount += 1
        lock.unlock()
    }
}

private struct RenderedHTMLContentMetrics {
    let variable: String
    let bodyWidth: Double
    let viewportWidth: Double

    var bodyToViewportRatio: Double {
        guard viewportWidth > 0 else { return 0 }
        return bodyWidth / viewportWidth
    }
}

private extension NSView {
    func descendantsForContentWidthTesting() -> [NSView] {
        subviews + subviews.flatMap { $0.descendantsForContentWidthTesting() }
    }
}
