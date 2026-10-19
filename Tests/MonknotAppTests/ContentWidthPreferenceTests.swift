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
                zoomScale: 1,
                fontSize: 14
            ),
            accuracy: 0.5
        )
        XCTAssertEqual(
            textView.bounds.width - 2 * (textView.textContainerInset.width + (textView.textContainer?.lineFragmentPadding ?? 0)),
            ContentWidthPreference.textColumnWidth(viewportWidth: textView.bounds.width, contentWidthPercent: 80, fontSize: 14),
            accuracy: 0.5,
            "The setting must describe the editable text column, not its margin"
        )
        XCTAssertEqual(
            ContentWidthPreference.textColumnWidth(viewportWidth: textView.bounds.width, contentWidthPercent: 80, fontSize: 14),
            640 * 14 / 13 * 80 / 88,
            accuracy: 0.5,
            "A wide pane stops at the comfortable measure, which follows the font size and the setting"
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
                zoomScale: 1,
                fontSize: 14
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
                zoomScale: 1,
                fontSize: 14
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
            ContentWidthPreference.editorVerticalInset(fontSize: 13 * WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.minimum)),
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
            ContentWidthPreference.editorVerticalInset(fontSize: 13 * WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.maximum)),
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

    /// A side pane's transition changes the editor's width on every frame and ends a live resize,
    /// after which AppKit scrolls to keep the insertion point in view. The line at the top of the
    /// window stays put instead (design.md §11), at the top of the document and partway down.
    func testAWidthChangeKeepsTheLineAtTheTopOfTheWindow() throws {
        var text = (1...240).map { "Line \($0): a sentence long enough to wrap once the column narrows." }
            .joined(separator: "\n")
        var sourceLocation: MarkdownSourceLocation?
        var searchState = DocumentSearchState()
        let host = NSHostingView(rootView: MarkdownTextEditor(
            documentID: "/anchor.md",
            text: Binding(get: { text }, set: { text = $0 }),
            theme: .defaultLight,
            fontSize: 13,
            zoomScale: 1,
            contentWidthPercent: 100,
            fontSmoothing: true,
            scrollPosition: nil,
            sourceLocation: Binding(get: { sourceLocation }, set: { sourceLocation = $0 }),
            searchState: Binding(get: { searchState }, set: { searchState = $0 }),
            onScrollPositionChange: { _ in }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendantsForContentWidthTesting().compactMap { $0 as? NSTextView }.first)
        let clip = try XCTUnwrap(textView.enclosingScrollView?.contentView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        func resize(to width: CGFloat) {
            textView.viewWillStartLiveResize()
            for step in 1...6 {
                host.frame.size.width = 900 + (width - 900) * CGFloat(step) / 6
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
            }
            textView.viewDidEndLiveResize()
        }

        func lineAtTop() -> Int {
            let point = NSPoint(x: 0, y: clip.bounds.minY - textView.textContainerOrigin.y + 1)
            let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
            let index = layoutManager.characterIndexForGlyph(at: glyph)
            return (textView.string as NSString).lineRange(for: NSRange(location: index, length: 0)).location
        }

        resize(to: 420)
        XCTAssertEqual(clip.bounds.minY, 0, accuracy: 0.5, "At the top it stays at the top")
        resize(to: 900)
        XCTAssertEqual(clip.bounds.minY, 0, accuracy: 0.5)

        let line = (textView.string as NSString).range(of: "Line 120:")
        let glyph = layoutManager.glyphIndexForCharacter(at: line.location)
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: glyph + 1))
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        clip.scroll(to: NSPoint(x: 0, y: rect.minY + textView.textContainerOrigin.y))
        textView.enclosingScrollView?.reflectScrolledClipView(clip)
        let top = lineAtTop()
        XCTAssertEqual(top, line.location)

        resize(to: 420)
        XCTAssertEqual(lineAtTop(), top, "Partway down, the same line stays at the top as the text rewraps")
        resize(to: 900)
        XCTAssertEqual(lineAtTop(), top)
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
        // The margin above the first line is 2.5 × the text size, Preview's too (DocumentMeasure).
        XCTAssertEqual(ContentWidthPreference.editorVerticalInset(fontSize: 13), 33)
        XCTAssertEqual(ContentWidthPreference.editorVerticalInset(fontSize: 17 * 1.75), 74)
        XCTAssertEqual(ContentWidthPreference.editorLineFragmentPadding(zoomScale: 1), 5)
        XCTAssertEqual(ContentWidthPreference.editorPlaceholderTopInset(fontSize: 13, zoomScale: 1), 41)
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
                fontSize: 13 * WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.minimum),
                zoomScale: WorkspaceZoomPolicy.minimum
            ),
            CGFloat(DocumentMeasure.verticalMargin(fontSize: 13 * WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.minimum)))
                + (8 * WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.minimum)).rounded()
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
                fontSize: 13 * WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.maximum),
                zoomScale: WorkspaceZoomPolicy.maximum
            ),
            CGFloat(DocumentMeasure.verticalMargin(fontSize: 13 * WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.maximum)))
                + (8 * WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.maximum)).rounded()
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
                resourceRoot: nil,
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
