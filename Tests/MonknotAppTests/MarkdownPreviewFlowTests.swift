import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

/// Writing assistance while Preview edits Markdown in place. These tests drive the real page in
/// WebKit through AppKit key events, with Source's checking client and models replaced by fakes, and
/// check what reaches the store: a fix is one source patch and one undo step, nothing is inserted
/// that the page did not show, and nothing runs inside code or links.
@MainActor
final class MarkdownPreviewFlowTests: WorkspaceStoreTestCase {
    private var hostWindows: [NSWindow] = []
    private var defaultsSuites: [String] = []

    override func tearDown() async throws {
        for window in hostWindows {
            window.contentView = nil
            window.close()
        }
        hostWindows.removeAll()
        for suite in defaultsSuites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        defaultsSuites.removeAll()
        try await super.tearDown()
    }

    // MARK: - Spelling and grammar repair

    func testDirectSpellingFixAppliesAsOneUndoStepAndDeleteRevertsIt() async throws {
        let checker = PreviewFlowChecker { text in
            PreviewFlowChecker.corrections(in: text, ["teh": "the"])
        }
        let fixture = try await makeFixture(markdown: "We read teh plan\n", checker: checker)
        let end = ("We read teh plan" as NSString).length
        try await fixture.setSelection(end)

        fixture.type(".")
        let fixed = await waitUntil { fixture.store.documentText == "We read the plan.\n" }
        XCTAssertTrue(fixed, "A certain fix applies once the sentence ends: \(fixture.store.documentText)")
        XCTAssertTrue(
            checker.requests.contains("We read teh plan."),
            "Source's planner chose the finished sentence before the caret: \(checker.requests)"
        )
        let undoManager = try XCTUnwrap(fixture.webView.undoManager)
        XCTAssertEqual(undoManager.undoActionName, "Accept Flow Correction", "The fix is its own undo step")
        let settled = await fixture.waitForFlowState { $0.settle != nil }
        XCTAssertTrue(settled, "The corrected word shimmers with ⌫ undo beside the caret")
        let marked = try await fixture.evaluate("[...document.querySelectorAll('.mk-flow-settled')].map(e => e.textContent).join('|')") as? String
        XCTAssertEqual(marked, "the")
        let caret = try await fixture.evaluate("window.MonknotEditor.selection().head") as? Int
        XCTAssertEqual(caret, ("We read the plan." as NSString).length, "The caret stays after the sentence")

        fixture.press(.backspace)
        let reverted = await waitUntil { fixture.store.documentText == "We read teh plan.\n" }
        XCTAssertTrue(reverted, "⌫ right after the fix takes it back, not the period: \(fixture.store.documentText)")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fixture.store.documentText, "We read teh plan.\n", "A taken-back fix is not offered again")
    }

    func testReviewedGrammarRepairShowsInPlaceAndTabAppliesIt() async throws {
        let checker = PreviewFlowChecker { text in
            text.contains(" is ") ? PreviewFlowChecker.grammar(in: text, target: "is", corrections: ["are"]) : []
        }
        let fixture = try await makeFixture(markdown: "They is **ready**\n", checker: checker)
        try await fixture.setSelection(("They is **ready**" as NSString).length)

        fixture.type(".")
        let shown = await fixture.waitForFlowState { $0.review?.rendered == true }
        XCTAssertTrue(shown, "A grammar repair that changes words waits for review")
        XCTAssertEqual(fixture.store.documentText, "They is **ready**.\n", "Nothing changes until the review is taken")
        let drawn = try await fixture.evaluate("""
        JSON.stringify({
          inserted: [...document.querySelectorAll('.mk-flow-insert')].map(e => e.textContent),
          hidden: [...document.querySelectorAll('.mk-flow-hidden')].map(e => e.textContent),
          keys: [...document.querySelectorAll('.mk-flow-hint kbd')].map(e => e.textContent),
          bold: document.querySelector('#content strong')?.textContent ?? ''
        })
        """) as? String
        XCTAssertEqual(
            drawn,
            #"{"inserted":["are"],"hidden":["is"],"keys":["⇥","Esc"],"bold":"ready"}"#,
            "The corrected word replaces the original in place; the sentence keeps its formatting"
        )

        fixture.press(.tab)
        let applied = await waitUntil { fixture.store.documentText == "They are **ready**.\n" }
        XCTAssertTrue(applied, "Tab applies the reviewed repair: \(fixture.store.documentText)")
        let undoManager = try XCTUnwrap(fixture.webView.undoManager)
        XCTAssertEqual(undoManager.undoActionName, "Accept Flow Correction")
        let leftovers = try await fixture.evaluate("document.querySelectorAll('.mk-flow-insert, .mk-flow-hidden').length") as? Int
        XCTAssertEqual(leftovers, 0, "The review leaves nothing behind in the page")

        undoManager.undo()
        let undone = await waitUntil { fixture.store.documentText == "They is **ready**.\n" }
        XCTAssertTrue(undone, "One undo takes the repair back: \(fixture.store.documentText)")
    }

    func testEscapeDismissesAReviewAndItIsNotOfferedAgain() async throws {
        let checker = PreviewFlowChecker { text in
            text.contains(" is ") ? PreviewFlowChecker.grammar(in: text, target: "is", corrections: ["are"]) : []
        }
        let fixture = try await makeFixture(markdown: "They is ready\n", checker: checker)
        let end = ("They is ready" as NSString).length
        try await fixture.setSelection(end)
        fixture.type(".")
        let shown = await fixture.waitForFlowState { $0.review?.rendered == true }
        XCTAssertTrue(shown)

        fixture.press(.escape)
        let dismissed = await fixture.waitForFlowState { $0.review == nil }
        XCTAssertTrue(dismissed, "Esc dismisses the review")
        XCTAssertEqual(fixture.store.documentText, "They is ready.\n", "Esc changes nothing")
        let hidden = try await fixture.evaluate("document.querySelectorAll('.mk-flow-hidden, .mk-flow-insert, .mk-flow-hint').length") as? Int
        XCTAssertEqual(hidden, 0, "The original words show again")

        let requestsBefore = checker.requests.count
        try await fixture.setSelection(0)
        try await fixture.setSelection(end + 1)
        let checkedAgain = await waitUntil { checker.requests.count > requestsBefore }
        XCTAssertTrue(checkedAgain, "Returning to the sentence checks it again")
        try await Task.sleep(nanoseconds: 300_000_000)
        let state = await fixture.flowState()
        XCTAssertNil(state?.review, "A dismissed repair is not offered again for the same sentence")
        XCTAssertEqual(fixture.store.documentText, "They is ready.\n")
    }

    func testRightArrowShowsTheNextAlternativeAndTabAppliesIt() async throws {
        let checker = PreviewFlowChecker { text in
            text == "They is ready." ? PreviewFlowChecker.grammar(in: text, target: "is", corrections: ["are", "were"]) : []
        }
        let fixture = try await makeFixture(markdown: "They is ready\n", checker: checker)
        try await fixture.setSelection(("They is ready" as NSString).length)
        fixture.type(".")
        let shown = await fixture.waitForFlowState { $0.review?.rendered == true && $0.review?.variants == 2 }
        XCTAssertTrue(shown, "Both alternatives check clean, so the review offers them")
        let finished = try XCTUnwrap(checker.requests.firstIndex(of: "They is ready."))
        XCTAssertEqual(
            Array(checker.requests[finished...].prefix(3)),
            ["They is ready.", "They are ready.", "They were ready."],
            "Each alternative is checked with Apple's checker before the review shows it"
        )
        let firstKeys = try await fixture.evaluate("[...document.querySelectorAll('.mk-flow-hint kbd')].map(e => e.textContent).join(' ')") as? String
        XCTAssertEqual(firstKeys, "⇥ → Esc")

        fixture.press(.right)
        let cycled = await fixture.waitForFlowState { $0.review?.index == 1 }
        XCTAssertTrue(cycled, "→ shows the next alternative")
        let inserted = try await fixture.evaluate("document.querySelector('.mk-flow-insert')?.textContent ?? ''") as? String
        XCTAssertEqual(inserted, "were")
        let caret = try await fixture.evaluate("window.MonknotEditor.selection().head") as? Int
        XCTAssertEqual(caret, ("They is ready." as NSString).length, "→ does not move the caret while alternatives show")

        fixture.press(.tab)
        let applied = await waitUntil { fixture.store.documentText == "They were ready.\n" }
        XCTAssertTrue(applied, "Tab applies the alternative on screen: \(fixture.store.documentText)")
    }

    func testASpaceAfterTheReviewedSentenceKeepsTheReview() async throws {
        let checker = PreviewFlowChecker { text in
            text.contains(" is ") ? PreviewFlowChecker.grammar(in: text, target: "is", corrections: ["are"]) : []
        }
        let fixture = try await makeFixture(markdown: "They is ready\n", checker: checker)
        try await fixture.setSelection(("They is ready" as NSString).length)
        fixture.type(".")
        let shown = await fixture.waitForFlowState { $0.review?.rendered == true }
        XCTAssertTrue(shown)

        fixture.type(" ")
        let kept = await fixture.waitForFlowState { $0.review?.rendered == true }
        XCTAssertTrue(kept, "One space after the sentence keeps its review, as in Source")
        XCTAssertEqual(fixture.store.documentText, "They is ready. \n")
        fixture.press(.tab)
        let applied = await waitUntil { fixture.store.documentText == "They are ready. \n" }
        XCTAssertTrue(applied, fixture.store.documentText)
        let caret = try await fixture.evaluate("window.MonknotEditor.selection().head") as? Int
        XCTAssertEqual(caret, ("They are ready. " as NSString).length, "The caret stays after the space")
    }

    /// Fixes land on the right characters wherever the sentence is: after emoji and CJK text (two
    /// UTF-16 units each for the emoji, on both sides of the bridge), in a list item and in a heading.
    func testFixesLandAfterEmojiAndInListItemsAndHeadings() async throws {
        let checker = PreviewFlowChecker { text in
            PreviewFlowChecker.corrections(in: text, ["teh": "the"])
        }
        let cases: [(source: String, caretAfter: String, fixed: String)] = [
            ("🙂 日本 We read teh plan\n", "🙂 日本 We read teh plan", "🙂 日本 We read the plan.\n"),
            ("- First item\n- We read teh plan\n", "- First item\n- We read teh plan", "- First item\n- We read the plan.\n"),
            ("## We read teh plan\n", "## We read teh plan", "## We read the plan.\n"),
        ]
        for (source, caretAfter, fixed) in cases {
            let fixture = try await makeFixture(markdown: source, checker: checker)
            try await fixture.setSelection((caretAfter as NSString).length)
            fixture.type(".")
            let applied = await waitUntil { fixture.store.documentText == fixed }
            XCTAssertTrue(applied, "\(source.debugDescription) became \(fixture.store.documentText.debugDescription)")
            let marked = try await fixture.evaluate("[...document.querySelectorAll('.mk-flow-settled')].map(e => e.textContent).join('|')") as? String
            XCTAssertEqual(marked, "the", "The mark sits on the corrected word in \(source.debugDescription)")
            let caret = try await fixture.evaluate("window.MonknotEditor.selection().head") as? Int
            XCTAssertEqual(caret, (fixed as NSString).length - 1, "The caret stays after the sentence")
            fixture.close()
        }

        let grammar = PreviewFlowChecker { text in
            text.contains(" is ") ? PreviewFlowChecker.grammar(in: text, target: "is", corrections: ["are"]) : []
        }
        let review = try await makeFixture(markdown: "🙂🙂 They is ready\n", checker: grammar)
        try await review.setSelection(("🙂🙂 They is ready" as NSString).length)
        review.type(".")
        let shown = await review.waitForFlowState { $0.review?.rendered == true }
        XCTAssertTrue(shown, "A review after emoji is drawn")
        let inserted = try await review.evaluate("[...document.querySelectorAll('.mk-flow-insert')].map(e => e.textContent).join('|')") as? String
        XCTAssertEqual(inserted, "are")
        review.press(.tab)
        let applied = await waitUntil { review.store.documentText == "🙂🙂 They are ready.\n" }
        XCTAssertTrue(applied, review.store.documentText.debugDescription)
    }

    func testTypingOnDropsALateCheckWithoutChangingAnything() async throws {
        let checker = PreviewFlowChecker { text in
            PreviewFlowChecker.corrections(in: text, ["teh": "the"])
        }
        checker.holdsAnswers = true
        let fixture = try await makeFixture(markdown: "We read teh plan\n", checker: checker)
        try await fixture.setSelection(("We read teh plan" as NSString).length)
        fixture.type(".")
        let asked = await waitUntil { checker.requests.contains("We read teh plan.") }
        XCTAssertTrue(asked, "The finished sentence is checked")

        fixture.type(" Then")
        let typed = await waitUntil { fixture.store.documentText == "We read teh plan. Then\n" }
        XCTAssertTrue(typed)
        checker.holdsAnswers = false
        checker.releaseHeldAnswers()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(
            fixture.store.documentText,
            "We read teh plan. Then\n",
            "An answer for text that has changed since is dropped, never applied"
        )
        XCTAssertNotEqual(fixture.webView.undoManager?.undoActionName, "Accept Flow Correction")
    }

    func testThePageRefusesAPatchForTextOrACaretThatMovedOn() async throws {
        let fixture = try await makeFixture(markdown: "We read teh plan.\n")
        let end = ("We read teh plan." as NSString).length
        try await fixture.setSelection(end)
        let version = try await fixture.evaluate("window.MonknotEditor.version()") as? Int
        let apply = { (base: Int, caret: Int) -> String in
            """
            window.MonknotEditor.flow({ type: 'apply', serial: 900, base: \(base), from: 8, to: 11,
              expected: 'teh', insert: 'the', selection: { anchor: \(end), head: \(end) },
              expectedSelection: { anchor: \(caret), head: \(caret) }, label: 'Accept Flow Correction',
              requireVisible: true, settle: { marks: [[0, 3]] } }); true
            """
        }
        try await fixture.evaluate(apply((version ?? 0) + 1, end))
        try await fixture.evaluate(apply(version ?? 0, end - 1))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fixture.store.documentText, "We read teh plan.\n", "A patch for an older text or another caret is refused")

        try await fixture.evaluate(apply(version ?? 0, end))
        let applied = await waitUntil { fixture.store.documentText == "We read the plan.\n" }
        XCTAssertTrue(applied, "The same patch for the current text and caret applies: \(fixture.store.documentText)")
    }

    /// ↩ checks the sentence it ends. The caret is then on an empty line, where no ⌫ undo hint can
    /// show, so ⌫ deletes the line as usual and the fix stays.
    func testReturnChecksTheSentenceItEndsAndBackspaceThenDeletesTheLine() async throws {
        let checker = PreviewFlowChecker { text in
            PreviewFlowChecker.corrections(in: text, ["teh": "the"])
        }
        let fixture = try await makeFixture(markdown: "We read teh plan\n", checker: checker)
        try await fixture.setSelection(("We read teh plan" as NSString).length)
        fixture.press(.return)
        let fixed = await waitUntil { fixture.store.documentText.hasPrefix("We read the plan\n") }
        XCTAssertTrue(fixed, "Return finishes the sentence, which is then checked: \(fixture.store.documentText)")
        XCTAssertEqual(checker.requests.first, "We read teh plan")
        let settled = await fixture.waitForFlowState { $0.settle != nil }
        XCTAssertTrue(settled, "The corrected word still shimmers")
        let state = await fixture.flowState()
        XCTAssertEqual(state?.settleRevertible, false, "⌫ is not taken over where its hint cannot show")
        let hints = try await fixture.evaluate("document.querySelectorAll('.mk-flow-hint').length") as? Int
        XCTAssertEqual(hints, 0)

        fixture.press(.backspace)
        let deleted = await waitUntil { fixture.store.documentText == "We read the plan\n" }
        XCTAssertTrue(deleted, "⌫ deletes the empty line and keeps the fix: \(fixture.store.documentText.debugDescription)")
    }

    /// ⌫ asks the app to take the fix back; when it cannot (here its undo step is no longer the last
    /// one), the page deletes as ⌫ would have, as Source falls through to an ordinary Backspace.
    func testARefusedRevertStillDeletes() async throws {
        let checker = PreviewFlowChecker { text in
            PreviewFlowChecker.corrections(in: text, ["teh": "the"])
        }
        let fixture = try await makeFixture(markdown: "We read teh plan\n", checker: checker)
        try await fixture.setSelection(("We read teh plan" as NSString).length)
        fixture.type(".")
        let fixed = await waitUntil { fixture.store.documentText == "We read the plan.\n" }
        XCTAssertTrue(fixed, fixture.store.documentText)
        let revertible = await fixture.waitForFlowState { $0.settleRevertible == true }
        XCTAssertTrue(revertible, "⌫ undo shows beside the caret")

        let undoManager = try XCTUnwrap(fixture.webView.undoManager)
        let unrelated = NSObject()
        undoManager.registerUndo(withTarget: unrelated) { _ in }
        undoManager.setActionName("Unrelated")
        defer { undoManager.removeAllActions(withTarget: unrelated) }

        fixture.press(.backspace)
        let deleted = await waitUntil { fixture.store.documentText == "We read the plan\n" }
        XCTAssertTrue(deleted, "⌫ deletes the period instead: \(fixture.store.documentText.debugDescription)")
    }

    /// Check Document Now starts over, so the ⌫ undo hint of the last fix goes with it and ⌫
    /// deletes again.
    func testCheckDocumentNowTakesTheUndoHintAway() async throws {
        let checker = PreviewFlowChecker { text in
            PreviewFlowChecker.corrections(in: text, ["teh": "the"])
        }
        let fixture = try await makeFixture(markdown: "We read teh plan\n", checker: checker)
        try await fixture.setSelection(("We read teh plan" as NSString).length)
        fixture.type(".")
        let revertible = await fixture.waitForFlowState { $0.settleRevertible == true }
        XCTAssertTrue(revertible)

        let commands = try XCTUnwrap((fixture.webView as? MarkdownEditorWebView)?.previewCommands)
        XCTAssertTrue(commands.checkDocumentNow())
        let cleared = await fixture.waitForFlowState { $0.settle == nil }
        XCTAssertTrue(cleared, "The page hears that the fix can no longer be taken back")
        fixture.press(.backspace)
        let deleted = await waitUntil { fixture.store.documentText == "We read the plan\n" }
        XCTAssertTrue(deleted, fixture.store.documentText.debugDescription)
    }

    func testCheckDocumentNowChecksTheSentenceAtTheCaret() async throws {
        let checker = PreviewFlowChecker { text in
            PreviewFlowChecker.corrections(in: text, ["teh": "the"])
        }
        let fixture = try await makeFixture(markdown: "We read teh plan\n", checker: checker)
        try await fixture.setSelection(("We read teh plan" as NSString).length)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fixture.store.documentText, "We read teh plan\n", "An unfinished sentence waits")

        let commands = try XCTUnwrap((fixture.webView as? MarkdownEditorWebView)?.previewCommands)
        XCTAssertTrue(commands.canCheckDocumentNow)
        XCTAssertTrue(commands.checkDocumentNow(), "Check Document Now runs in Preview")
        let fixed = await waitUntil { fixture.store.documentText == "We read the plan\n" }
        XCTAssertTrue(fixed, "The sentence at the caret is checked at once: \(fixture.store.documentText)")
    }

    /// A certain fix the page declines (its sentence scrolled out of view before the answer came)
    /// was never made, so the next check offers it again instead of treating it as taken.
    func testAFixThePageDeclinedIsOfferedAgainOnTheNextCheck() async throws {
        let checker = PreviewFlowChecker { text in
            PreviewFlowChecker.corrections(in: text, ["teh": "the"])
        }
        let filler = String(repeating: "Another paragraph of notes for the week.\n\n", count: 80)
        let fixture = try await makeFixture(markdown: "We read teh plan\n\n" + filler, checker: checker)
        try await fixture.setSelection(("We read teh plan" as NSString).length)
        checker.holdsAnswers = true
        fixture.type(".")
        let asked = await waitUntil { checker.requests.contains("We read teh plan.") && checker.heldCount > 0 }
        XCTAssertTrue(asked, "The finished sentence is checked")

        try await fixture.evaluate("window.scrollTo(0, document.documentElement.scrollHeight); true")
        try await Task.sleep(nanoseconds: 100_000_000)
        checker.holdsAnswers = false
        checker.releaseHeldAnswers()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(
            fixture.store.documentText,
            "We read teh plan.\n\n" + filler,
            "A fix whose sentence is out of view is not made"
        )

        try await fixture.evaluate("window.scrollTo(0, 0); true")
        try await Task.sleep(nanoseconds: 100_000_000)
        let commands = try XCTUnwrap((fixture.webView as? MarkdownEditorWebView)?.previewCommands)
        XCTAssertTrue(commands.checkDocumentNow())
        let fixed = await waitUntil { fixture.store.documentText == "We read the plan.\n\n" + filler }
        XCTAssertTrue(fixed, "The declined fix is offered again: \(fixture.store.documentText.prefix(40))")
    }

    /// A certain fix is on its way to the page when the caret moves to another sentence, so the page
    /// declines it. That answer was about the old caret: the check at the new one must still ask
    /// the on-device model about a sentence Apple flagged but could not fix.
    func testADeclineForAnOldCaretLeavesTheNextSentenceToTheModel() async throws {
        let first = "We read teh plan."
        let second = "Their going home."
        let source = first + "\n\n" + second + "\n"
        let repairs = SentenceRepairRequests()
        var dependencies = MarkdownPreviewFlowDependencies()
        dependencies.checkingClient = EditorFlowCheckingClient({ text, _, _, _, completion in
            if text.contains("teh") {
                completion(PreviewFlowChecker.corrections(in: text, ["teh": "the"]), PreviewFlowChecker.english)
            } else if text == second {
                // A grammar issue without a precise range resolves into no fix.
                let whole = NSRange(location: 0, length: (text as NSString).length)
                completion([NSTextCheckingResult.grammarCheckingResult(range: whole, details: [])], PreviewFlowChecker.english)
            } else {
                completion([], PreviewFlowChecker.english)
            }
        })
        dependencies.sentenceRepairService = FlowSentenceRepairService(isAvailable: { _ in true }) { request, _ in
            repairs.append(request.sentence)
            return nil
        }
        dependencies.proseCompletionService = FlowProseCompletionService(isAvailable: { _ in false }) { _, _ in nil }
        dependencies.checkDelayNanoseconds = 0
        dependencies.protectedRangesDelayNanoseconds = 0
        dependencies.protectedRangeProvider = { _, _ in [] }
        dependencies.windowFocusValidator = { _ in true }
        let host = RecordingPreviewFlowHost()
        let flow = MarkdownPreviewFlowCoordinator(dependencies: dependencies)
        defer { flow.tearDown() }
        flow.host = host
        flow.prepare(documentID: "Note.md")
        flow.configure(options: Self.onDevice)
        flow.pageDidRender(text: source)
        flow.pageDidChangeFocus(true)

        let firstEnd = (first as NSString).length
        flow.pageDidChangeSelection(MarkdownVisualEditorSelection(anchor: firstEnd, head: firstEnd), version: 0, focused: true)
        let sent = await waitUntil { host.messages.contains { $0["type"] as? String == "apply" } }
        XCTAssertTrue(sent, "The certain fix is sent to the page: \(host.messages)")
        let apply = try XCTUnwrap(host.messages.last { $0["type"] as? String == "apply" })

        let secondEnd = (source as NSString).length - 1
        flow.pageDidChangeSelection(MarkdownVisualEditorSelection(anchor: secondEnd, head: secondEnd), version: 0, focused: true)
        flow.handlePageMessage(["action": "declined", "serial": try XCTUnwrap(apply["serial"] as? Int)])
        let asked = await waitUntil { repairs.sentences.contains(second) }
        XCTAssertTrue(asked, "The model is asked about the sentence at the new caret: \(repairs.sentences)")
    }

    // MARK: - On-device writing assistance

    func testOnDeviceRepairIsReviewedAfterAppleChecksIt() async throws {
        let checker = PreviewFlowChecker { _ in [] }
        let repair = FlowSentenceRepairService(isAvailable: { _ in true }) { request, _ in
            request.sentence == "Their going home." ? "They're going home." : nil
        }
        let fixture = try await makeFixture(
            markdown: "Their going home\n",
            checker: checker,
            sentenceRepair: repair,
            options: Self.onDevice
        )
        try await fixture.setSelection(("Their going home" as NSString).length)
        fixture.type(".")
        let shown = await fixture.waitForFlowState { $0.review?.rendered == true }
        XCTAssertTrue(shown, "The model's repair is offered for review, never applied by itself")
        XCTAssertEqual(fixture.store.documentText, "Their going home.\n")
        XCTAssertTrue(checker.requests.contains("They're going home."), "Apple checks the model's sentence before it shows")

        fixture.press(.tab)
        let applied = await waitUntil { fixture.store.documentText == "They're going home.\n" }
        XCTAssertTrue(applied, fixture.store.documentText)
    }

    func testCompletionShowsOnlyWhenTheSettingsAndTheModelAllowIt() async throws {
        let unavailable = FlowProseCompletionSpy(isAvailable: false, result: "clearer prose.")
        let noModel = try await makeFixture(markdown: "We can write\n", prose: unavailable, options: Self.onDevice)
        try await noModel.setSelection(("We can write" as NSString).length)
        noModel.type(" ")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(unavailable.requestCount, 0, "No model, no request")
        var state = await noModel.flowState()
        XCTAssertNil(state?.ghost)
        noModel.close()

        let disabled = FlowProseCompletionSpy(result: "clearer prose.")
        let settingOff = try await makeFixture(markdown: "We can write\n", prose: disabled)
        try await settingOff.setSelection(("We can write" as NSString).length)
        settingOff.type(" ")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(disabled.requestCount, 0, "On-device writing assistance is off by default")
        settingOff.close()

        let predictionsOff = FlowProseCompletionSpy(result: "clearer prose.")
        let masterOff = try await makeFixture(
            markdown: "We can write\n",
            prose: predictionsOff,
            options: EditorTextCheckingOptions(checksSpelling: true, checksGrammar: true, inlinePredictions: false, onDeviceProseCompletions: true)
        )
        try await masterOff.setSelection(("We can write" as NSString).length)
        masterOff.type(" ")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(predictionsOff.requestCount, 0, "Inline predictions off turns completions off, as in Source")
        masterOff.close()

        let available = FlowProseCompletionSpy(result: "clearer prose.")
        let fixture = try await makeFixture(markdown: "We can write\n", prose: available, options: Self.onDevice)
        try await fixture.setSelection(("We can write" as NSString).length)
        fixture.type(" ")
        let shown = await fixture.waitForFlowState { $0.ghost?.rendered == true }
        XCTAssertTrue(shown, "A completion shows after the caret")
        XCTAssertEqual(available.requests.map(\.context), ["We can write "])
        state = await fixture.flowState()
        XCTAssertEqual(state?.ghost?.text, "clearer prose.")
        let page = try await fixture.evaluate("""
        JSON.stringify({
          ghost: document.querySelector('.mk-flow-ghost-text')?.textContent ?? '',
          editable: document.querySelector('.mk-flow-ghost')?.getAttribute('contenteditable'),
          keys: [...document.querySelectorAll('.mk-flow-ghost .mk-flow-hint kbd')].map(e => e.textContent)
        })
        """) as? String
        XCTAssertEqual(page, #"{"ghost":"clearer prose.","editable":"false","keys":["⇥"]}"#)
        XCTAssertEqual(fixture.store.documentText, "We can write \n", "A completion is only drawn, never written")
        let caret = try await fixture.evaluate("window.MonknotEditor.selection().head") as? Int
        XCTAssertEqual(caret, ("We can write " as NSString).length, "The caret stays before the completion")
    }

    func testTabTakesOneWordAndAHeldTabTakesTheRestAsOneUndoStep() async throws {
        let prose = FlowProseCompletionSpy(result: "clearly, with confidence.")
        let fixture = try await makeFixture(markdown: "We can write\n", prose: prose, options: Self.onDevice)
        try await fixture.setSelection(("We can write" as NSString).length)
        fixture.type(" ")
        let shown = await fixture.waitForFlowState { $0.ghost?.rendered == true }
        XCTAssertTrue(shown)

        fixture.press(.tab)
        let word = await waitUntil { fixture.store.documentText == "We can write clearly, \n" }
        XCTAssertTrue(word, "A tap takes the next word: \(fixture.store.documentText)")
        let undoManager = try XCTUnwrap(fixture.webView.undoManager)
        XCTAssertEqual(undoManager.undoActionName, "Accept Flow Word")
        let remainder = await fixture.waitForFlowState { $0.ghost?.text == "with confidence." && $0.ghost?.rendered == true }
        XCTAssertTrue(remainder, "The rest of the completion comes back once the sentence checks clean")

        await fixture.hold(.tab, for: 0.6)
        let all = await waitUntil { fixture.store.documentText == "We can write clearly, with confidence.\n" }
        XCTAssertTrue(all, "Holding Tab takes all of it: \(fixture.store.documentText)")
        XCTAssertEqual(undoManager.undoActionName, "Accept Flow Completion")
        XCTAssertFalse(fixture.store.documentText.contains("\t"), "A held Tab's repeats insert nothing")

        undoManager.undo()
        let undone = await waitUntil { fixture.store.documentText == "We can write clearly, \n" }
        XCTAssertTrue(undone, "The held Tab was one undo step: \(fixture.store.documentText)")
    }

    func testTypingWhatTheCompletionShowsKeepsTheRest() async throws {
        let prose = FlowProseCompletionSpy(result: "clearer prose.")
        let fixture = try await makeFixture(markdown: "We can write\n", prose: prose, options: Self.onDevice)
        try await fixture.setSelection(("We can write" as NSString).length)
        fixture.type(" ")
        let shown = await fixture.waitForFlowState { $0.ghost?.rendered == true }
        XCTAssertTrue(shown)

        fixture.type("cl")
        let consumed = await fixture.waitForFlowState { $0.ghost?.text == "earer prose." && $0.ghost?.rendered == true }
        XCTAssertTrue(consumed, "Typed letters that match the completion consume it")
        XCTAssertEqual(fixture.store.documentText, "We can write cl\n")
        await fixture.hold(.tab, for: 0.6)
        let all = await waitUntil { fixture.store.documentText == "We can write clearer prose.\n" }
        XCTAssertTrue(all, "Tab takes what is still shown: \(fixture.store.documentText)")
        XCTAssertEqual(prose.requestCount, 1, "Consuming the completion asks the model nothing new")
    }

    /// The tint on a word Tab just took must not touch a composition started right after it: a dead
    /// key (⌥E then E) or an input method keeps its marked text and caret past the tint's end, and
    /// commits once, where it was typed.
    func testACompositionRightAfterTakingAWordSurvivesTheTint() async throws {
        let prose = FlowProseCompletionSpy(result: "clearly.")
        let fixture = try await makeFixture(markdown: "We can write\n", prose: prose, options: Self.onDevice)
        try await fixture.setSelection(("We can write" as NSString).length)
        fixture.type(" ")
        let shown = await fixture.waitForFlowState { $0.ghost?.rendered == true }
        XCTAssertTrue(shown)
        try await fixture.evaluate("""
        window.__composition = [];
        for (const type of ['compositionstart', 'compositionend']) {
          document.getElementById('content').addEventListener(type, (event) => window.__composition.push(type));
        }
        true
        """)

        fixture.press(.tab)
        let taken = await waitUntil { fixture.store.documentText == "We can write clearly.\n" }
        XCTAssertTrue(taken, fixture.store.documentText)
        let tinted = try await fixture.evaluate("document.querySelectorAll('.mk-flow-flash').length") as? Int
        XCTAssertEqual(tinted, 1, "The taken word is tinted for a moment")

        // ⌥E: a dead key opens a composition with marked text, inside the tint's 600 ms.
        let input = try XCTUnwrap(fixture.webView as? NSTextInputClient)
        let noReplacement = NSRange(location: NSNotFound, length: 0)
        input.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: noReplacement)
        let composing = await waitUntil {
            ((try? await fixture.evaluate("window.__composition.join(' ')")) as? String) == "compositionstart"
        }
        XCTAssertTrue(composing, "The composition started")
        try await Task.sleep(nanoseconds: 900_000_000)
        let events = try await fixture.evaluate("window.__composition.join(' ')") as? String
        XCTAssertEqual(events, "compositionstart", "Nothing ended the composition when the tint went")
        let beforeCaret = try await fixture.evaluate("""
        (() => {
          const selection = getSelection();
          const range = document.createRange();
          range.setStart(document.getElementById('content'), 0);
          range.setEnd(selection.focusNode, selection.focusOffset);
          return range.toString();
        })()
        """) as? String
        XCTAssertEqual(beforeCaret, "We can write clearly.´", "The marked text and the caret after it survive")

        // E: the dead key's character replaces the marked text, once.
        input.insertText("é", replacementRange: noReplacement)
        let committed = await waitUntil { fixture.store.documentText == "We can write clearly.é\n" }
        XCTAssertTrue(committed, "Committed once, where typed: \(fixture.store.documentText.debugDescription)")
        let caret = try await fixture.evaluate("window.MonknotEditor.selection().head") as? Int
        XCTAssertEqual(caret, ("We can write clearly.é" as NSString).length)
    }

    func testEscapeAndOtherKeysDismissTheCompletion() async throws {
        let prose = FlowProseCompletionSpy(result: "clearer prose.")
        let fixture = try await makeFixture(markdown: "We can write\n", prose: prose, options: Self.onDevice)
        try await fixture.setSelection(("We can write" as NSString).length)
        fixture.type(" ")
        let shown = await fixture.waitForFlowState { $0.ghost?.rendered == true }
        XCTAssertTrue(shown)

        fixture.press(.escape)
        let dismissed = await fixture.waitForFlowState { $0.ghost == nil }
        XCTAssertTrue(dismissed, "Esc dismisses the completion")
        XCTAssertEqual(fixture.store.documentText, "We can write \n")
        let leftover = try await fixture.evaluate("document.querySelectorAll('.mk-flow-ghost').length") as? Int
        XCTAssertEqual(leftover, 0)

        fixture.type("x")
        let typed = await waitUntil { fixture.store.documentText == "We can write x\n" }
        XCTAssertTrue(typed, "Typing something else keeps what was typed: \(fixture.store.documentText)")
        fixture.press(.tab)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(fixture.store.documentText.contains("clearer"), "Nothing that is not shown is ever inserted")
    }

    // MARK: - Protected Markdown

    func testNothingIsRepairedInsideCodeOrLinkAddresses() async throws {
        let checker = PreviewFlowChecker { text in
            PreviewFlowChecker.corrections(in: text, ["teh": "the"])
        }
        for source in ["Use `teh value` here", "Read [notes](teh.md) here", "See https://teh.example.com here"] {
            let fixture = try await makeFixture(markdown: source + "\n", checker: checker)
            try await fixture.setSelection((source as NSString).length)
            fixture.type(".")
            let checked = await waitUntil { checker.requests.contains(source + ".") }
            XCTAssertTrue(checked, "The sentence is checked")
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(fixture.store.documentText, source + ".\n", "Code and link text are never changed")
            let state = await fixture.flowState()
            XCTAssertNil(state?.review)
            XCTAssertNil(state?.settle)
            fixture.close()
        }

        // A link's text is prose, as in Source: only its address is protected.
        let label = try await makeFixture(markdown: "Read [teh notes](Notes.md) here\n", checker: checker)
        try await label.setSelection(("Read [teh notes](Notes.md) here" as NSString).length)
        label.type(".")
        let fixed = await waitUntil { label.store.documentText == "Read [the notes](Notes.md) here.\n" }
        XCTAssertTrue(fixed, label.store.documentText)
    }

    func testCompletionNeverStartsInsideCode() async throws {
        let prose = FlowProseCompletionSpy(result: "with a useful ending.")
        let fixture = try await makeFixture(markdown: "Plain words `code value`\n", prose: prose, options: Self.onDevice)
        try await fixture.setSelection(("Plain words `code value" as NSString).length)
        fixture.type("x")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(prose.requestCount, 0, "No completion is asked for inside code")
        let state = await fixture.flowState()
        XCTAssertNil(state?.ghost)
    }

    /// A sentence in a table cell starts in another cell, so a reviewed fix could never be drawn
    /// there: Preview checks, fixes and completes nothing while the caret is in a cell. (Source
    /// checks the words in cells; only a table's pipes are protected.)
    func testNothingIsCheckedFixedOrCompletedInATableCell() async throws {
        let checker = PreviewFlowChecker { text in
            PreviewFlowChecker.corrections(in: text, ["teh": "the"])
        }
        let prose = FlowProseCompletionSpy(result: "for the whole team.")
        let source = "| Task | Notes |\n| --- | --- |\n| Plan | We read teh plan |\n| Next | We can write |\n\nWe read teh notes\n"
        let fixture = try await makeFixture(markdown: source, checker: checker, prose: prose, options: Self.onDevice)

        let planEnd = NSMaxRange((source as NSString).range(of: "We read teh plan"))
        try await fixture.setSelection(planEnd)
        fixture.type(".")
        let typed = await waitUntil { fixture.store.documentText.contains("| We read teh plan. |") }
        XCTAssertTrue(typed, fixture.store.documentText)
        let commands = try XCTUnwrap((fixture.webView as? MarkdownEditorWebView)?.previewCommands)
        XCTAssertFalse(commands.canCheckDocumentNow, "Check Document Now has nothing to check in a cell")

        let writeEnd = NSMaxRange((fixture.store.documentText as NSString).range(of: "We can write"))
        try await fixture.setSelection(writeEnd)
        fixture.type(" ")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(fixture.store.documentText.contains("| We read teh plan. |"), "Nothing in a cell is fixed")
        XCTAssertEqual(checker.requests, [], "Nothing in a cell is checked")
        XCTAssertEqual(prose.requestCount, 0, "Nothing in a cell is completed")
        let state = await fixture.flowState()
        XCTAssertNil(state?.review)
        XCTAssertNil(state?.ghost)
        XCTAssertNil(state?.settle)

        // Below the table, it all runs again.
        let notesEnd = NSMaxRange((fixture.store.documentText as NSString).range(of: "We read teh notes"))
        try await fixture.setSelection(notesEnd)
        fixture.type(".")
        let fixed = await waitUntil { fixture.store.documentText.hasSuffix("\nWe read the notes.\n") }
        XCTAssertTrue(fixed, fixture.store.documentText)
    }

    // MARK: - Tab keeps its meanings

    func testTabStillIndentsListItemsAndMovesBetweenCellsWithoutASuggestion() async throws {
        let checker = PreviewFlowChecker { text in
            PreviewFlowChecker.corrections(in: text, ["teh": "the"])
        }
        let list = try await makeFixture(markdown: "- First\n- Second\n", checker: checker)
        try await list.setSelection(("- First\n- Sec" as NSString).length)
        list.press(.tab)
        let indented = await waitUntil { list.store.documentText != "- First\n- Second\n" }
        XCTAssertTrue(indented, "Tab indents the list item")
        XCTAssertTrue(list.store.documentText.hasSuffix("- Second\n"), list.store.documentText)
        XCTAssertFalse(list.store.documentText.contains("\n- Second"), "The item moved under the one above: \(list.store.documentText)")
        list.press(.shiftTab)
        let outdented = await waitUntil { list.store.documentText == "- First\n- Second\n" }
        XCTAssertTrue(outdented, "⇧Tab outdents it again: \(list.store.documentText)")
        list.close()

        let tableSource = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        let table = try await makeFixture(markdown: tableSource, checker: checker)
        try await table.setSelection((tableSource as NSString).range(of: "1 |").location + 1)
        table.press(.tab)
        table.type("3")
        let moved = await waitUntil { table.store.documentText.contains("| 1 | 23 |") || table.store.documentText.contains("| 1 | 3 |") }
        XCTAssertTrue(moved, "Tab moves to the next cell: \(table.store.documentText)")
    }

    func testTheNoteMenuKeepsTabWhileACompletionCouldShow() async throws {
        let prose = FlowProseCompletionSpy(result: "of the week.")
        let checker = PreviewFlowChecker { _ in [] }
        let fixture = try await makeFixture(
            markdown: "See the notes in \n",
            checker: checker,
            prose: prose,
            options: Self.onDevice,
            notes: ["Project Plan Review.md"]
        )
        try await fixture.setSelection(("See the notes in " as NSString).length)
        fixture.type("[[")
        let menu = await waitUntil {
            ((try? await fixture.evaluate("Boolean(document.querySelector('.mk-menu.mk-visible'))")) as? Bool) == true
        }
        XCTAssertTrue(menu, "The note menu opens")

        // Every character typed into the open menu could ask for a completion: "Project Plan " is
        // two words after the protected brackets, enough for the model.
        let requestsBeforeMenu = prose.requestCount
        let checksBeforeMenu = checker.requests.count
        fixture.type("Project Plan ")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(prose.requestCount, requestsBeforeMenu, "The model is asked nothing while the note menu is open")
        XCTAssertEqual(checker.requests.count, checksBeforeMenu, "Nothing is checked while the note menu is open")
        let state = await fixture.flowState()
        XCTAssertNil(state?.ghost, "No completion shows while a menu is over the text")
        fixture.press(.tab)
        let linked = await waitUntil { fixture.store.documentText == "See the notes in [[Project Plan Review]]\n" }
        XCTAssertTrue(linked, "Tab chooses the note: \(fixture.store.documentText)")
    }

    /// A two-word query in the slash menu ("bulleted lis") is context enough for a completion, yet
    /// while the menu is open nothing is checked and the model is asked nothing. Esc closes it
    /// without an edit, and checking resumes then, as after a caret move.
    func testTheSlashMenuAsksNothingWhileOpenAndEscapeResumesChecking() async throws {
        let prose = FlowProseCompletionSpy(result: "of every task.")
        let checker = PreviewFlowChecker { _ in [] }
        let fixture = try await makeFixture(
            markdown: "Notes for the week.\n\n",
            checker: checker,
            prose: prose,
            options: Self.onDevice
        )
        try await fixture.setSelection(("Notes for the week.\n\n" as NSString).length)
        let menuIsOpen = {
            ((try? await fixture.evaluate("Boolean(document.querySelector('.mk-menu.mk-visible'))")) as? Bool) == true
        }
        fixture.type("/")
        let opened = await waitUntil { await menuIsOpen() }
        XCTAssertTrue(opened, "The slash menu opens at the start of a block")

        let requestsBeforeMenu = prose.requestCount
        let checksBeforeMenu = checker.requests.count
        fixture.type("bulleted lis")
        try await Task.sleep(nanoseconds: 400_000_000)
        let stillOpen = await menuIsOpen()
        XCTAssertTrue(stillOpen, "The query keeps the menu open")
        XCTAssertEqual(prose.requestCount, requestsBeforeMenu, "The model is asked nothing while the slash menu is open")
        XCTAssertEqual(checker.requests.count, checksBeforeMenu, "Nothing is checked while the slash menu is open")

        fixture.press(.escape)
        let closed = await waitUntil { await !menuIsOpen() }
        XCTAssertTrue(closed, "Esc closes the slash menu")
        let checkedAgain = await waitUntil { checker.requests.count > checksBeforeMenu }
        XCTAssertTrue(checkedAgain, "Checking resumes once the menu is gone: \(checker.requests)")
    }

    // MARK: - Settings

    func testTurningTheSettingsOffStopsEverything() async throws {
        let checker = PreviewFlowChecker { text in
            PreviewFlowChecker.corrections(in: text, ["teh": "the"])
        }
        let prose = FlowProseCompletionSpy(result: "clearer prose.")
        let fixture = try await makeFixture(
            markdown: "We read teh plan\n",
            checker: checker,
            prose: prose,
            options: EditorTextCheckingOptions(checksSpelling: false, checksGrammar: false, inlinePredictions: false, onDeviceProseCompletions: false)
        )
        let spellcheckOff = await fixture.waitForFlowState { $0.spellcheck == false }
        XCTAssertTrue(spellcheckOff, "Check Spelling While Typing off turns the page's spelling marks off")
        let attribute = try await fixture.evaluate("document.getElementById('content').getAttribute('spellcheck')") as? String
        XCTAssertEqual(attribute, "false")
        try await fixture.setSelection(("We read teh plan" as NSString).length)
        fixture.type(". We")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(checker.requests, [], "Nothing is checked")
        XCTAssertEqual(prose.requestCount, 0, "Nothing is completed")
        XCTAssertEqual(fixture.store.documentText, "We read teh plan. We\n")

        fixture.set(EditorTextCheckingOptions(checksSpelling: true, checksGrammar: true, inlinePredictions: true, onDeviceProseCompletions: false))
        let spellcheckOn = await fixture.waitForFlowState { $0.spellcheck == true }
        XCTAssertTrue(spellcheckOn, "Turning it back on applies at once")
        fixture.type(".")
        let checked = await waitUntil { !checker.requests.isEmpty }
        XCTAssertTrue(checked, "Checking resumes")
    }

    // MARK: - Writing Tools and system predictions

    func testShowWritingToolsSwitchesToSource() async throws {
        let fixture = try await makeFixture(markdown: "Plain prose here\n", writingToolsAvailable: true)
        try await fixture.setSelection(5)
        let commands = try XCTUnwrap((fixture.webView as? MarkdownEditorWebView)?.previewCommands)
        XCTAssertTrue(commands.canShowWritingTools, "Show Writing Tools is enabled in Preview")
        XCTAssertTrue(commands.showWritingTools())
        XCTAssertEqual(fixture.harness.editorMode, .source, "Writing Tools open in Source, which rewrites text in place")
        let sourceFocused = await waitUntil {
            guard let textView = fixture.documentTextView() else { return false }
            return fixture.window.firstResponder === textView
        }
        XCTAssertTrue(sourceFocused, "Source takes keyboard focus for Writing Tools")
        XCTAssertEqual(fixture.store.documentText, "Plain prose here\n")
    }

    func testWritingToolsCommandIsOffWhenWritingToolsAreUnavailable() async throws {
        let fixture = try await makeFixture(markdown: "Plain prose here\n", writingToolsAvailable: false)
        try await fixture.setSelection(5)
        let commands = try XCTUnwrap((fixture.webView as? MarkdownEditorWebView)?.previewCommands)
        XCTAssertFalse(commands.canShowWritingTools)
        XCTAssertFalse(commands.showWritingTools())
        XCTAssertEqual(fixture.harness.editorMode, .preview)
    }

    /// WebKit's Ignore Spelling ignores the word in WebKit's own spelling document; the writing
    /// assistance checks in another, so the item ignores the word there too and still reaches WebKit.
    func testIgnoreSpellingInThePageMenuAlsoIgnoresTheWordForWritingAssistance() async throws {
        let fixture = try await makeFixture(markdown: "We read tehh plan\n")
        let start = ("We read " as NSString).length
        try await fixture.setSelection(start, start + 4)
        let webView = try XCTUnwrap(fixture.webView as? MarkdownEditorWebView)
        let flow = try XCTUnwrap(webView.writingAssistance, "Flow registers with the page it runs on")
        XCTAssertFalse(NSSpellChecker.shared.ignoredWords(inSpellDocumentWithTag: flow.spellDocumentTag)?.contains("tehh") == true)

        let webKit = WebKitMenuTargetStandIn()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Ignore Spelling", action: NSSelectorFromString("forwardContextMenuAction:"), keyEquivalent: "")
        item.tag = MarkdownEditorWebView.webKitIgnoreSpellingTag
        item.target = webKit
        menu.addItem(item)
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        webView.willOpenMenu(menu, with: click)
        menu.performActionForItem(at: 0)

        XCTAssertEqual(webKit.forwardedTags, [MarkdownEditorWebView.webKitIgnoreSpellingTag], "WebKit still ignores it")
        let ignored = await waitUntil {
            NSSpellChecker.shared.ignoredWords(inSpellDocumentWithTag: flow.spellDocumentTag)?.contains("tehh") == true
        }
        XCTAssertTrue(ignored, "The writing assistance ignores the selected word in its own spelling document")
    }

    func testSystemInlinePredictionsStayOffInPreview() async throws {
        let fixture = try await makeFixture(markdown: "Plain prose here\n")
        XCTAssertFalse(
            fixture.webView.configuration.allowsInlinePredictions,
            "WebKit's own predictions would write into the page outside a source patch (design.md §10.10)"
        )
    }

    private static let onDevice = EditorTextCheckingOptions(
        checksSpelling: true,
        checksGrammar: true,
        inlinePredictions: true,
        onDeviceProseCompletions: true
    )

    // MARK: - Fixture

    private func makeFixture(
        markdown: String,
        checker suppliedChecker: PreviewFlowChecker? = nil,
        prose: FlowProseCompletionSpy? = nil,
        sentenceRepair: FlowSentenceRepairService? = nil,
        options: EditorTextCheckingOptions = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true,
            onDeviceProseCompletions: false
        ),
        writingToolsAvailable: Bool = false,
        notes: [String] = [],
        width: CGFloat = 800
    ) async throws -> PreviewFlowFixture {
        let checker = suppliedChecker ?? PreviewFlowChecker { _ in [] }
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotPreviewFlow")
        let file = root.appendingPathComponent("Note.md")
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        for note in notes {
            let url = root.appendingPathComponent(note)
            try "# \(url.deletingPathExtension().lastPathComponent)\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let store = makeWorkspaceStore()
        store.openWorkspace(root, selecting: file)
        let loaded = await waitUntil(timeout: 10) {
            !store.isBusy && store.selectedDocument?.displayName == "Note.md" && !store.isDocumentLoading
                && store.markdownDocuments.count == notes.count + 1
        }
        XCTAssertTrue(loaded, "Workspace did not load")
        store.testing_stopFileWatcher()

        let suite = "Monknot.PreviewFlowTests.\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        PreviewFlowHarnessModel.write(options, to: defaults)

        var dependencies = MarkdownPreviewFlowDependencies()
        dependencies.checkingClient = checker.client
        if let prose {
            dependencies.proseCompletionService = prose.service
        } else {
            dependencies.proseCompletionService = FlowProseCompletionService(isAvailable: { _ in false }) { _, _ in nil }
        }
        dependencies.sentenceRepairService = sentenceRepair
            ?? FlowSentenceRepairService(isAvailable: { _ in false }) { _, _ in nil }
        dependencies.checkDelayNanoseconds = 20_000_000
        dependencies.proseCompletionDelayNanoseconds = 0
        dependencies.proseOfferDelayNanoseconds = 0
        dependencies.protectedRangesDelayNanoseconds = 0
        dependencies.windowFocusValidator = { _ in true }
        dependencies.writingToolsAvailability = { writingToolsAvailable }

        let harness = PreviewFlowHarnessModel(store: store, defaults: defaults, dependencies: dependencies)
        let window = KeyTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // AppKit animates a window's ordering on a GCD worker thread. With the screen locked the
        // animation never ends, so every test window would hold a worker for good, and once the
        // pool runs dry WebKit's page loads stall in later tests.
        window.animationBehavior = .none
        let host = NSHostingView(rootView: PreviewFlowHarness(model: harness).frame(width: width, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        hostWindows.append(window)
        let fixture = PreviewFlowFixture(store: store, harness: harness, window: window, host: host, test: self)
        _ = try await fixture.waitForEditor()
        return fixture
    }

    fileprivate func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }
}

/// What the page reports it shows (`MonknotEditor.flowState()`).
struct PreviewFlowPageState {
    struct Review {
        let serial: Int
        let index: Int
        let variants: Int
        let rendered: Bool
    }

    struct Ghost {
        let serial: Int
        let at: Int
        let text: String
        let rendered: Bool
    }

    let spellcheck: Bool
    let review: Review?
    let ghost: Ghost?
    /// The caret a just-applied fix shimmers for, and whether ⌫ there takes it back.
    let settle: Int?
    let settleRevertible: Bool?

    init?(_ value: Any?) {
        guard let body = value as? [String: Any] else { return nil }
        spellcheck = (body["spellcheck"] as? Bool) ?? true
        if let review = body["review"] as? [String: Any] {
            self.review = Review(
                serial: (review["serial"] as? Int) ?? 0,
                index: (review["index"] as? Int) ?? 0,
                variants: (review["variants"] as? Int) ?? 0,
                rendered: (review["rendered"] as? Bool) ?? false
            )
        } else {
            review = nil
        }
        if let ghost = body["ghost"] as? [String: Any] {
            self.ghost = Ghost(
                serial: (ghost["serial"] as? Int) ?? 0,
                at: (ghost["at"] as? Int) ?? 0,
                text: (ghost["text"] as? String) ?? "",
                rendered: (ghost["rendered"] as? Bool) ?? false
            )
        } else {
            ghost = nil
        }
        let settled = body["settle"] as? [String: Any]
        settle = settled?["caret"] as? Int
        settleRevertible = settled?["revertible"] as? Bool
    }
}

/// A checking client that answers at once with what `results` returns for the checked text, or
/// holds each answer until the test releases it.
@MainActor
final class PreviewFlowChecker {
    private(set) var requests: [String] = []
    private var held: [EditorFlowCheckingClient.Completion] = []
    var holdsAnswers = false
    var results: (String) -> [NSTextCheckingResult]

    init(results: @escaping (String) -> [NSTextCheckingResult]) {
        self.results = results
    }

    var heldCount: Int { held.count }

    var client: EditorFlowCheckingClient {
        EditorFlowCheckingClient({ [weak self] text, _, _, _, completion in
            MainActor.assumeIsolated {
                guard let self else {
                    completion([], nil)
                    return
                }
                self.requests.append(text)
                if self.holdsAnswers {
                    let answer = self.results(text)
                    self.held.append { _, _ in completion(answer, Self.english) }
                    return
                }
                completion(self.results(text), Self.english)
            }
        }, requestCandidates: { _, _, _, _, completion in
            completion([])
        })
    }

    func releaseHeldAnswers() {
        let answers = held
        held.removeAll()
        for answer in answers {
            answer([], nil)
        }
    }

    static let english = NSOrthography(dominantScript: "Latn", languageMap: ["Latn": ["en"]])

    static func corrections(in text: String, _ replacements: [String: String]) -> [NSTextCheckingResult] {
        let source = text as NSString
        return replacements.compactMap { original, replacement in
            let range = source.range(of: original)
            guard range.location != NSNotFound else { return nil }
            return NSTextCheckingResult.correctionCheckingResult(range: range, replacementString: replacement)
        }
    }

    static func grammar(in text: String, target: String, corrections: [String]) -> [NSTextCheckingResult] {
        let source = text as NSString
        let range = source.range(of: target)
        guard range.location != NSNotFound else { return [] }
        return [NSTextCheckingResult.grammarCheckingResult(
            range: NSRange(location: 0, length: source.length),
            details: [[NSGrammarRange: NSValue(range: range), NSGrammarCorrections: corrections]]
        )]
    }
}

@MainActor
final class PreviewFlowFixture {
    let store: WorkspaceStore
    let harness: PreviewFlowHarnessModel
    let window: NSWindow
    let host: NSView
    unowned let test: MarkdownPreviewFlowTests
    private(set) var webView: WKWebView!

    init(store: WorkspaceStore, harness: PreviewFlowHarnessModel, window: NSWindow, host: NSView, test: MarkdownPreviewFlowTests) {
        self.store = store
        self.harness = harness
        self.window = window
        self.host = host
        self.test = test
    }

    func waitForEditor(timeout: TimeInterval = 10) async throws -> WKWebView {
        let ready = await test.waitUntil(timeout: timeout) {
            guard let webView = self.findWebView() else { return false }
            let active = (try? await webView.evaluateJavaScript("Boolean(window.MonknotEditor && window.MonknotEditor.isActive() && window.MonknotEditor.source() !== null)")) as? Bool
            if active == true {
                self.webView = webView
                return true
            }
            return false
        }
        XCTAssertTrue(ready, "The editor did not become active")
        return try XCTUnwrap(webView)
    }

    func findWebView() -> WKWebView? {
        descendants(of: WKWebView.self, in: host).first
    }

    func documentTextView() -> NSTextView? {
        descendants(of: NSTextView.self, in: host).first { $0.identifier == .monknotDocumentFocusTarget }
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let match = view as? T { result.append(match) }
        for subview in view.subviews { result += descendants(of: type, in: subview) }
        return result
    }

    @discardableResult
    func evaluate(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    func setSelection(_ anchor: Int, _ head: Int? = nil) async throws {
        window.makeFirstResponder(webView)
        let ok = try await evaluate("window.MonknotEditor.setSelection(\(anchor), \(head ?? anchor))") as? Bool
        XCTAssertEqual(ok, true)
        try await Task.sleep(nanoseconds: 60_000_000)
    }

    func flowState() async -> PreviewFlowPageState? {
        PreviewFlowPageState(try? await evaluate("window.MonknotEditor.flowState()"))
    }

    func waitForFlowState(
        timeout: TimeInterval = 5,
        _ condition: @escaping (PreviewFlowPageState) -> Bool
    ) async -> Bool {
        await test.waitUntil(timeout: timeout) {
            guard let state = await self.flowState() else { return false }
            return condition(state)
        }
    }

    enum Key {
        case `return`
        case backspace
        case escape
        case tab
        case shiftTab
        case right
        case character(String)

        var characters: String {
            switch self {
            case .return: return "\r"
            case .backspace: return "\u{7F}"
            case .escape: return "\u{1B}"
            case .tab, .shiftTab: return "\t"
            case .right: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case .character(let value): return value
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .return: return 36
            case .backspace: return 51
            case .escape: return 53
            case .tab, .shiftTab: return 48
            case .right: return 124
            case .character: return 0
            }
        }

        var modifiers: NSEvent.ModifierFlags {
            if case .shiftTab = self { return .shift }
            return []
        }
    }

    /// Types through AppKit's key handling, as a keyboard would.
    func type(_ text: String) {
        for character in text {
            keyboard.send(characters: String(character), keyCode: 0)
        }
    }

    func press(_ key: Key) {
        keyboard.send(characters: key.characters, keyCode: key.keyCode, modifiers: key.modifiers)
    }

    /// Holds a key down for `duration` with a repeat or two, as a held key would.
    func hold(_ key: Key, for duration: TimeInterval) async {
        keyboard.send([.keyDown], characters: key.characters, keyCode: key.keyCode, modifiers: key.modifiers)
        let deadline = Date().addingTimeInterval(duration)
        var repeated = false
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if !repeated, deadline.timeIntervalSinceNow < duration / 2 {
                keyboard.send([.keyDown], characters: key.characters, keyCode: key.keyCode, modifiers: key.modifiers, isRepeat: true)
                repeated = true
            }
        }
        keyboard.send([.keyUp], characters: key.characters, keyCode: key.keyCode, modifiers: key.modifiers)
    }

    private var keyboard: PageKeyboard {
        PageKeyboard(window: window, webView: { self.webView })
    }

    func set(_ options: EditorTextCheckingOptions) {
        PreviewFlowHarnessModel.write(options, to: harness.defaults)
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

@MainActor
final class PreviewFlowHarnessModel: ObservableObject {
    let store: WorkspaceStore
    let defaults: UserDefaults
    let dependencies: MarkdownPreviewFlowDependencies
    @Published var editorMode = EditorMode.preview

    init(store: WorkspaceStore, defaults: UserDefaults, dependencies: MarkdownPreviewFlowDependencies) {
        self.store = store
        self.defaults = defaults
        self.dependencies = dependencies
    }

    static func write(_ options: EditorTextCheckingOptions, to defaults: UserDefaults) {
        defaults.set(options.checksSpelling, forKey: EditorTextCheckingOptions.spellingPreferenceKey)
        defaults.set(options.checksGrammar, forKey: EditorTextCheckingOptions.grammarPreferenceKey)
        defaults.set(options.inlinePredictions, forKey: EditorTextCheckingOptions.inlinePredictionsPreferenceKey)
        defaults.set(options.onDeviceProseCompletions, forKey: EditorTextCheckingOptions.onDeviceProseCompletionsPreferenceKey)
    }
}

/// The editor pane as `ContentView` mounts it, in Preview with no split, reading its settings from
/// the test's own defaults and running the writing assistance with the test's fakes.
private struct PreviewFlowHarness: View {
    @ObservedObject var model: PreviewFlowHarnessModel
    @State private var isSplitViewEnabled = false
    @State private var sourceLocation: MarkdownSourceLocation?
    @State private var previewLocation: MarkdownSourceLocation?
    @State private var pdfSearchTarget: WorkspaceSearchPDFTarget?
    @State private var documentSearch = DocumentSearchState()
    @StateObject private var pdfViewportCaptureBridge = PDFViewportCaptureBridge()

    var body: some View {
        EditorPaneView(
            store: model.store,
            editorMode: $model.editorMode,
            isSplitViewEnabled: $isSplitViewEnabled,
            theme: .defaultLight,
            zoomScale: 1,
            codeFontSize: 13,
            contentWidthPercent: 88,
            showsDocumentOutline: false,
            usePointerCursors: false,
            fontSmoothing: true,
            activeViewportState: nil,
            pdfViewportCaptureBridge: pdfViewportCaptureBridge,
            updateViewportState: { _, _ in },
            pdfUndoCommandSerial: 0,
            pdfRedoCommandSerial: 0,
            updatePDFAnnotationUndoState: { _, _ in },
            sourceLocation: $sourceLocation,
            previewLocation: $previewLocation,
            pdfSearchTarget: $pdfSearchTarget,
            pdfPageNavigationRequest: nil,
            pdfNavigatorToggleCommandSerial: 0,
            documentSearch: $documentSearch,
            searchOptions: MonknotSearchOptions(),
            newMarkdown: {},
            bootstrapStarterWorkspace: {},
            openFolder: {},
            saveDocument: {},
            outlineItems: [],
            textStatistics: nil,
            selectOutlineItem: { _ in },
            onPreviewSourceJump: { _ in },
            copyPDFLinkedExcerpt: { _ in },
            updatePDFSelectionSnapshot: { _ in },
            consumePDFPageNavigationRequest: { _ in },
            onMarkdownSelectionChange: { _ in },
            onMarkdownLinkRequest: { _ in },
            onInspectLinks: nil,
            onMarkdownImagePasteRequest: { _ in },
            onMarkdownFileDropRequest: { _ in },
            onMarkdownPreviewLinkRequest: { _ in },
            onMarkdownTaskRequest: { _ in }
        )
        .defaultAppStorage(model.defaults)
        .environment(\.markdownPreviewFlowDependencies, model.dependencies)
    }
}

/// The sentences Preview's writing assistance asked the on-device model to repair.
final class SentenceRepairRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var sentences: [String] {
        lock.withLock { recorded }
    }

    func append(_ sentence: String) {
        lock.withLock { recorded.append(sentence) }
    }
}

/// A page stand-in for `MarkdownPreviewFlowCoordinator`: it records what the app sends.
@MainActor
final class RecordingPreviewFlowHost: MarkdownPreviewFlowHost {
    let flowFocusView: NSView? = NSView()
    let flowUndoManager: UndoManager? = UndoManager()
    private(set) var messages: [[String: Any]] = []

    func sendFlow(_ message: [String: Any]) {
        messages.append(message)
    }
}

/// Stands in for WebKit's menu target, which receives every item of the page's context menu.
final class WebKitMenuTargetStandIn: NSObject {
    private(set) var forwardedTags: [Int] = []

    @objc func forwardContextMenuAction(_ sender: Any?) {
        forwardedTags.append((sender as? NSMenuItem)?.tag ?? -1)
    }
}
