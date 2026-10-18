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

    func testReturnChecksTheSentenceItEnds() async throws {
        let checker = PreviewFlowChecker { text in
            PreviewFlowChecker.corrections(in: text, ["teh": "the"])
        }
        let fixture = try await makeFixture(markdown: "We read teh plan\n", checker: checker)
        try await fixture.setSelection(("We read teh plan" as NSString).length)
        fixture.press(.return)
        let fixed = await waitUntil { fixture.store.documentText.hasPrefix("We read the plan\n") }
        XCTAssertTrue(fixed, "Return finishes the sentence, which is then checked: \(fixture.store.documentText)")
        XCTAssertEqual(checker.requests.first, "We read teh plan")
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
        let fixture = try await makeFixture(
            markdown: "See the notes in\n",
            prose: prose,
            options: Self.onDevice,
            notes: ["Project Plan.md"]
        )
        try await fixture.setSelection(("See the notes in" as NSString).length)
        fixture.type(" [[Pro")
        let menu = await waitUntil {
            ((try? await fixture.evaluate("Boolean(document.querySelector('.mk-menu.mk-visible'))")) as? Bool) == true
        }
        XCTAssertTrue(menu, "The note menu opens")
        try await Task.sleep(nanoseconds: 300_000_000)
        let state = await fixture.flowState()
        XCTAssertNil(state?.ghost, "No completion shows while a menu is over the text")
        fixture.press(.tab)
        let linked = await waitUntil { fixture.store.documentText == "See the notes in [[Project Plan]]\n" }
        XCTAssertTrue(linked, "Tab chooses the note: \(fixture.store.documentText)")
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

    // MARK: - System predictions

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

        let harness = PreviewFlowHarnessModel(store: store, defaults: defaults, dependencies: dependencies)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
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
    let settle: Int?

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
        settle = (body["settle"] as? [String: Any])?["caret"] as? Int
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
            send(.keyDown, characters: String(character), keyCode: 0)
            send(.keyUp, characters: String(character), keyCode: 0)
            pump()
        }
    }

    func press(_ key: Key) {
        send(.keyDown, characters: key.characters, keyCode: key.keyCode, modifiers: key.modifiers)
        send(.keyUp, characters: key.characters, keyCode: key.keyCode, modifiers: key.modifiers)
        pump()
    }

    /// Holds a key down for `duration` with a repeat or two, as a held key would.
    func hold(_ key: Key, for duration: TimeInterval) async {
        send(.keyDown, characters: key.characters, keyCode: key.keyCode, modifiers: key.modifiers)
        pump()
        let deadline = Date().addingTimeInterval(duration)
        var repeated = false
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if !repeated, deadline.timeIntervalSinceNow < duration / 2 {
                send(.keyDown, characters: key.characters, keyCode: key.keyCode, modifiers: key.modifiers, isRepeat: true)
                repeated = true
            }
        }
        send(.keyUp, characters: key.characters, keyCode: key.keyCode, modifiers: key.modifiers)
        pump()
    }

    private func send(
        _ type: NSEvent.EventType,
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false
    ) {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isRepeat,
            keyCode: keyCode
        ) else { return }
        window.sendEvent(event)
    }

    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
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
