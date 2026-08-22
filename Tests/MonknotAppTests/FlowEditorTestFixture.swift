import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

/// Short enough to keep the corpus fast, but long enough to coalesce character typing.
private let testFlowCheckDelayNanoseconds: UInt64 = 20_000_000

@MainActor
class FlowEditorTestCase: XCTestCase {

    func assertInlinePredictionURLCompletionFailsClosed(mode: FlowSourceMode) async {
        let source = "example.c"
        let box = EditorTextBox(source)
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        textView.flowSourceMode = mode
        textView.applyTextChecking(EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true
        ))
        coordinator.configureFlow(mode: mode, options: .defaultValue)
        let initialScanFinished = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(initialScanFinished)
        XCTAssertEqual(textView.inlinePredictionType, .no)

        textView.insertText("o", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "example.co")
        XCTAssertEqual(textView.inlinePredictionType, .no)
        let refreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(refreshBlocked)
        XCTAssertEqual(textView.inlinePredictionType, .no)

        provider.resumeBlockedCall()
        let currentScanFinished = await waitUntil(timeout: 3) {
            textView.flowWritingToolsReady && provider.activeCallCount == 0
        }
        XCTAssertTrue(currentScanFinished)
        XCTAssertEqual(textView.inlinePredictionType, .no)
    }

    func assertGrammarOnlyAlternativeRejectsValidationResult(
        _ validationResult: @escaping (String, NSRange) -> NSTextCheckingResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let source = "thse lanterns is ready"
        let completedSource = source + "."
        let box = EditorTextBox(source)
        var requestedTexts: [String] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestedTexts.append(checkedText)
                let checkedSource = checkedText as NSString
                let unrelatedSpelling = NSTextCheckingResult.correctionCheckingResult(
                    range: checkedSource.range(of: "thse"),
                    replacementString: "these"
                )
                if checkedText == completedSource {
                    completion([
                        unrelatedSpelling,
                        self.grammarResult(
                            in: checkedText,
                            target: "is",
                            corrections: ["are", "were"]
                        ),
                    ], self.englishOrthography())
                } else if checkedText.contains(" are ") {
                    let targetRange = checkedSource.range(of: "are")
                    completion([
                        unrelatedSpelling,
                        validationResult(checkedText, targetRange),
                    ], self.englishOrthography())
                } else {
                    completion([unrelatedSpelling], self.englishOrthography())
                }
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady, file: file, line: line)
        var acceptedSuggestion: EditorFlowSuggestion?
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptedSuggestion = suggestion
            return coordinator.acceptFlowSuggestion(suggestion)
        }

        textView.insertText(".", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.correctedSentence == "thse lanterns were ready."
        }
        XCTAssertTrue(suggestionReady, file: file, line: line)
        XCTAssertEqual(
            textView.flowSuggestion?.acceptance,
            .reviewOnly,
            file: file,
            line: line
        )
        await renderFlowSuggestion(in: textView, window: window)
        guard let tabEvent = keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Could not create Tab event", file: file, line: line)
            return
        }
        textView.keyDown(with: tabEvent)
        let settled = await waitUntil { textView.string == "thse lanterns were ready." }

        XCTAssertTrue(settled, file: file, line: line)
        XCTAssertEqual(Array(requestedTexts.prefix(3)), [
            "thse lanterns is ready.",
            "thse lanterns are ready.",
            "thse lanterns were ready.",
        ], file: file, line: line)
        XCTAssertNil(textView.flowSuggestion, file: file, line: line)
        XCTAssertEqual(acceptedSuggestion?.edits.map(\.originalText), ["is"], file: file, line: line)
        XCTAssertEqual(acceptedSuggestion?.edits.map(\.replacementText), ["were"], file: file, line: line)
        XCTAssertFalse(
            acceptedSuggestion?.exactChangeDescription.contains("thse") == true,
            file: file,
            line: line
        )
    }

    func assertAmbiguousGrammarValidationAbstains(
        cleanReplacements: Set<String>
    ) async {
        let source = "They is ready"
        let box = EditorTextBox(source)
        var requestedTexts: [String] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestedTexts.append(checkedText)
                if checkedText == source + "." {
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: "is",
                            corrections: ["are", "were"]
                        ),
                    ], self.englishOrthography())
                    return
                }

                let replacement = checkedText.contains(" are ") ? "are" : "were"
                if cleanReplacements.contains(replacement) {
                    completion([], self.englishOrthography())
                } else {
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: replacement,
                            corrections: ["is"]
                        ),
                    ], self.englishOrthography())
                }
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let validationFinished = await waitUntil { requestedTexts.count == 3 }
        XCTAssertTrue(validationFinished)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(requestedTexts, [
            "They is ready.",
            "They are ready.",
            "They were ready.",
        ])
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "They is ready.")
        XCTAssertEqual(box.value, "They is ready.")
    }

    func frozenSourceMode(for testCase: FlowWritingRepairCase) -> FlowSourceMode {
        if testCase.expectation == .protectedUnsafe { return .markdown }
        let suffix = testCase.id.split(separator: "-").last.flatMap { Int($0) } ?? 1
        return suffix.isMultiple(of: 2) ? .plainText : .markdown
    }

    func frozenCorpusFlowCheckDelay(for inputPath: FrozenCorpusInputPath) -> UInt64 {
        switch inputPath {
        case .characterTyping, .pasteboard:
            return testFlowCheckDelayNanoseconds
        }
    }

    func runFrozenCoordinatorCorpus(
        inputPath: FrozenCorpusInputPath,
        shard: FrozenCorpusShard
    ) async throws {
        assertFrozenHostedCorpusContract()
        var exactCount = 0
        var protectedCount = 0
        var cleanCount = 0
        var aiDirectCount = 0
        var aiReviewCount = 0
        var aiRejectedCount = 0
        var markdownCount = 0
        var plainTextCount = 0
        var elapsedCases: [(id: String, milliseconds: Double)] = []
        let allCoordinatorCases = FlowWritingCorpus.repairCases.filter {
            $0.expectation != .aiInvariant
        }.sorted { left, right in
            if left.id == "repair-exact-022" { return true }
            if right.id == "repair-exact-022" { return false }
            return left.id < right.id
        }
        XCTAssertEqual(allCoordinatorCases.count, 40)
        let coordinatorCases = shard.includesNonAI ? allCoordinatorCases : []
        for testCase in coordinatorCases {
            if frozenSourceMode(for: testCase) == .plainText {
                plainTextCount += 1
            } else {
                markdownCount += 1
            }
            let startedAt = Date()
            switch testCase.expectation {
            case .exactDeterministic:
                exactCount += 1
                try await runFrozenDeterministicCorpusCase(testCase, inputPath: inputPath)
            case .protectedUnsafe:
                protectedCount += 1
                try await runFrozenProtectedCorpusCase(testCase, inputPath: inputPath)
            case .clean:
                cleanCount += 1
                try await runFrozenCleanCorpusCase(testCase, inputPath: inputPath)
            case .aiInvariant:
                XCTFail("Unexpected AI case in deterministic coordinator selection: \(testCase.id)")
            }
            elapsedCases.append((
                id: testCase.id,
                milliseconds: Date().timeIntervalSince(startedAt) * 1_000
            ))
        }

        let allAICases = FlowWritingCorpus.repairCases.filter {
            $0.expectation == .aiInvariant
        }.sorted { $0.id < $1.id }
        XCTAssertEqual(allAICases.count, 20)
        let aiCases = allAICases.filter { shard.includesAI(id: $0.id) }
        for testCase in aiCases {
            if frozenSourceMode(for: testCase) == .plainText {
                plainTextCount += 1
            } else {
                markdownCount += 1
            }
            let startedAt = Date()
            switch try await runFrozenAICorpusCase(testCase, inputPath: inputPath) {
            case .direct:
                aiDirectCount += 1
            case .review:
                aiReviewCount += 1
            case .rejected:
                aiRejectedCount += 1
            }
            elapsedCases.append((
                id: testCase.id,
                milliseconds: Date().timeIntervalSince(startedAt) * 1_000
            ))
        }

        XCTAssertEqual(exactCount, shard.includesNonAI ? 24 : 0)
        XCTAssertEqual(protectedCount, shard.includesNonAI ? 10 : 0)
        XCTAssertEqual(cleanCount, shard.includesNonAI ? 6 : 0)
        XCTAssertEqual(aiDirectCount, 0)
        XCTAssertEqual(aiReviewCount, aiCases.count)
        XCTAssertEqual(aiRejectedCount, 0)
        XCTAssertEqual(
            markdownCount + plainTextCount,
            coordinatorCases.count + aiCases.count
        )
        XCTAssertEqual(
            plainTextCount,
            (coordinatorCases + aiCases).filter { frozenSourceMode(for: $0) == .plainText }.count
        )
        let sortedElapsed = elapsedCases.map(\.milliseconds).sorted()
        let median = sortedElapsed[sortedElapsed.count / 2]
        let slowest = sortedElapsed.last ?? 0
        let medianText = String(format: "%.1f", median)
        let slowestText = String(format: "%.1f", slowest)
        print(
            "FLOW_CORPUS_RUNTIME path=\(inputPath) shard=\(shard) "
                + "executions=\(elapsedCases.count) "
                + "exact=\(exactCount) aiDirect=\(aiDirectCount) aiReview=\(aiReviewCount) "
                + "aiRejected=\(aiRejectedCount) protected=\(protectedCount) clean=\(cleanCount) "
                + "markdown=\(markdownCount) plainText=\(plainTextCount) "
                + "medianMs=\(medianText) slowestMs=\(slowestText)"
        )
        print(
            "FLOW_CORPUS_CASE_RUNTIME path=\(inputPath) shard=\(shard) "
                + elapsedCases.map {
                    "\($0.id):\(String(format: "%.1f", $0.milliseconds))"
                }.joined(separator: ",")
        )
    }

    func assertFrozenHostedCorpusContract() {
        let cases = FlowWritingCorpus.repairCases
        XCTAssertEqual(cases.count, 60)
        XCTAssertEqual(cases.filter { $0.expectation == .exactDeterministic }.count, 24)
        XCTAssertEqual(cases.filter { $0.expectation == .protectedUnsafe }.count, 10)
        XCTAssertEqual(cases.filter { $0.expectation == .clean }.count, 6)
        XCTAssertEqual(cases.filter { $0.expectation == .aiInvariant }.count, 20)
        XCTAssertEqual(cases.filter { frozenSourceMode(for: $0) == .plainText }.count, 25)
        XCTAssertEqual(cases.filter { frozenSourceMode(for: $0) == .markdown }.count, 35)
    }

    func runFrozenDeterministicCorpusCase(
        _ testCase: FlowWritingRepairCase,
        inputPath: FrozenCorpusInputPath
    ) async throws {
        let box = EditorTextBox("")
        let diagnostics = FlowDiagnosticEventBox()
        var checkerTrace: [String] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                guard let reference = self.corpusReferenceSlice(
                    for: checkedText,
                    in: testCase
                ) else {
                    checkerTrace.append("checked=\(checkedText.debugDescription) reference=nil")
                    completion([], self.englishOrthography())
                    return
                }
                let results = self.corpusCorrectionResults(
                    in: checkedText,
                    reference: reference
                )
                checkerTrace.append(
                    "checked=\(checkedText.debugDescription) "
                        + "reference=\(reference.debugDescription) results=\(results.count)"
                )
                completion(
                    results,
                    self.englishOrthography()
                )
            },
            flowCheckDelayNanoseconds: frozenCorpusFlowCheckDelay(for: inputPath)
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: ""
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false
        )
        let sourceMode = frozenSourceMode(for: testCase)
        textView.flowSourceMode = sourceMode
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: sourceMode, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(
            rangesReady,
            "Protected ranges did not settle for \(testCase.id)"
        )
        let acceptanceCount = EditorIntBox()
        var acceptedSuggestion: EditorFlowSuggestion?
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptedSuggestion = suggestion
            acceptanceCount.value += 1
            return coordinator.acceptFlowSuggestion(suggestion)
        }
        textView.undoManager?.removeAllActions()

        let triggeredDocument = try await enterFrozenCorpusCase(
            testCase,
            inputPath: inputPath,
            textView: textView,
            window: window,
            diagnostics: diagnostics
        )

        let suggestionReady = await waitUntil(timeout: 3) {
            acceptedSuggestion?.source == .deterministic
                || textView.flowSuggestion?.source == .deterministic
        }
        XCTAssertTrue(
            suggestionReady,
            "No exact deterministic proposal for \(testCase.id) via \(inputPath); "
                + checkerTrace.joined(separator: " | ")
        )
        let suggestion = try XCTUnwrap(
            acceptedSuggestion ?? textView.flowSuggestion,
            "Missing deterministic result for \(testCase.id)"
        )
        XCTAssertEqual(suggestion.source, .deterministic)
        let hasLetterDeletingSpellingRepair = suggestion.edits.contains { edit in
            edit.kind == .spelling
                && edit.replacementText.filter { $0.isLetter || $0.isNumber }.count
                    < edit.originalText.filter { $0.isLetter || $0.isNumber }.count
        }
        XCTAssertEqual(
            suggestion.acceptance,
            hasLetterDeletingSpellingRepair ? .reviewOnly : .direct
        )
        if ["repair-exact-021", "repair-exact-022", "repair-exact-023"].contains(testCase.id) {
            XCTAssertEqual(suggestion.sentenceRange, NSRange(
                location: 0,
                length: (testCase.input as NSString).length
            ))
            XCTAssertEqual(suggestion.originalSentence, testCase.input)
            XCTAssertEqual(suggestion.correctedSentence, testCase.referenceText)
        }
        let reference = try XCTUnwrap(corpusReferenceSlice(
            for: suggestion.originalSentence,
            in: testCase
        ))
        XCTAssertEqual(suggestion.correctedSentence, reference)
        XCTAssertFalse(suggestion.displayChanges.isEmpty)
        let terminalEvent = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .sentenceRepair,
            reason: .visibleDeterministicRepair
        )
        XCTAssertLessThanOrEqual(
            terminalEvent?.elapsedMilliseconds ?? .max,
            2_000,
            "Repair exceeded the deterministic corpus latency budget for \(testCase.id)"
        )
        let expectedDocument = NSMutableString(string: triggeredDocument)
        expectedDocument.replaceCharacters(
            in: suggestion.sentenceRange,
            with: suggestion.correctedSentence
        )
        let acceptedDocument = expectedDocument as String
        let layoutMode = suggestion.acceptance
        if layoutMode == .reviewOnly {
            textView.undoManager?.removeAllActions()
            await renderFlowSuggestion(in: textView, window: window)
            XCTAssertTrue(textView.canApplyRenderedFlowSuggestion(suggestion))
            XCTAssertTrue(textView.isFlowReviewPreviewShown)
            XCTAssertEqual(textView.string, triggeredDocument)
            XCTAssertEqual(box.value, triggeredDocument)
            await replaceFrozenReviewSuggestion(
                suggestion,
                expectedDocument: acceptedDocument,
                originalDocument: triggeredDocument,
                acceptanceCount: acceptanceCount,
                box: box,
                textView: textView,
                window: window,
                testCaseID: testCase.id
            )
            return
        }
        let settled = await waitUntil { textView.string == acceptedDocument }
        XCTAssertTrue(settled, "Automatic settlement timed out for \(testCase.id)")
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, acceptedDocument, "Acceptance mismatch for \(testCase.id)")
        XCTAssertEqual(box.value, acceptedDocument, "Binding mismatch for \(testCase.id)")
        XCTAssertEqual(acceptanceCount.value, 1, "Acceptance count mismatch for \(testCase.id)")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, triggeredDocument, "Undo mismatch for \(testCase.id)")
        textView.undoManager?.redo()
        XCTAssertEqual(textView.string, acceptedDocument, "Redo mismatch for \(testCase.id)")
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: (acceptedDocument as NSString).length, length: 0),
            "Redo caret mismatch for \(testCase.id)"
        )
    }

    func runFrozenAICorpusCase(
        _ testCase: FlowWritingRepairCase,
        inputPath: FrozenCorpusInputPath
    ) async throws -> FrozenAICorpusOutcome {
        let box = EditorTextBox("")
        let diagnostics = FlowDiagnosticEventBox()
        let validation = FlowCorrectionEditsBox()
        let candidate = testCase.conservativeCandidateFixture ?? testCase.referenceText
        let sentenceRepair = FlowSentenceRepairService(
            isAvailable: { _ in true },
            client: { _, _ in candidate }
        )
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                if checkedText == candidate {
                    completion([], self.englishOrthography())
                    return
                }
                let issueRanges = self.corpusDifferenceRanges(
                    in: checkedText,
                    candidate: candidate
                )
                let detectedIssues = self.corpusDetectedIssues(
                    in: checkedText,
                    candidate: candidate,
                    issueRanges: issueRanges,
                    testCase: testCase
                )
                validation.capture(EditorFlowAIRepairValidator.edits(
                    originalSentence: checkedText,
                    candidateSentence: candidate
                ))
                completion(
                    self.corpusCheckingResults(
                        in: checkedText,
                        detectedIssues: detectedIssues
                    ),
                    self.englishOrthography()
                )
            },
            sentenceRepair: sentenceRepair,
            flowCheckDelayNanoseconds: frozenCorpusFlowCheckDelay(for: inputPath)
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
        let frozenTextView = FrozenCorpusTextView()
        frozenTextView.rejectsSyntheticCantCorrection = testCase.input.contains("cant") && {
            if case .characterTyping = inputPath { return true }
            return false
        }()
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: "",
            textView: frozenTextView
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false,
            onDeviceProseCompletions: true
        )
        let sourceMode = frozenSourceMode(for: testCase)
        textView.flowSourceMode = sourceMode
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: sourceMode, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(
            rangesReady,
            "Protected ranges did not settle for \(testCase.id)"
        )
        let acceptanceCount = EditorIntBox()
        var acceptedSuggestion: EditorFlowSuggestion?
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptedSuggestion = suggestion
            acceptanceCount.value += 1
            return coordinator.acceptFlowSuggestion(suggestion)
        }
        textView.undoManager?.removeAllActions()

        let triggeredDocument = try await enterFrozenCorpusCase(
            testCase,
            inputPath: inputPath,
            textView: textView,
            window: window,
            diagnostics: diagnostics
        )
        let classified = await waitUntil(timeout: 3) { validation.wasCaptured }
        XCTAssertTrue(classified, "AI fixture was not classified: \(testCase.id)")
        if frozenTextView.rejectsSyntheticCantCorrection {
            // AppKit may or may not attempt this correction depending on the
            // checker process's learned state. If it does, the test view
            // records and rejects only that exact replacement; strict input
            // equality below remains the invariant in either state.
            XCTAssertLessThanOrEqual(
                frozenTextView.rejectedSyntheticCantCorrectionCount,
                1,
                "The CLI-only native correction repeated for \(testCase.id)"
            )
        }

        guard let expectedEdits = validation.value else {
            XCTFail(
                "AI review fixture failed structural validation: \(testCase.id)"
            )
            let rejected = await waitUntil(timeout: 3) {
                diagnostics.events.contains {
                    $0.owner == .sentenceRepair && $0.reason == .validationRejected
                }
            }
            XCTAssertTrue(
                rejected,
                "Unsafe AI fixture was not rejected for \(testCase.id) via \(inputPath)"
            )
            let terminal = await assertSingleDiagnosticAttempt(
                diagnostics,
                owner: .sentenceRepair,
                reason: .validationRejected
            )
            XCTAssertTrue(terminal?.nativeFallbackRestored == true)
            XCTAssertNil(textView.flowSuggestion)
            XCTAssertEqual(textView.string, triggeredDocument)
            XCTAssertEqual(box.value, triggeredDocument)
            return .rejected
        }

        let suggestionReady = await waitUntil(timeout: 3) {
            acceptedSuggestion?.source == .ai || textView.flowSuggestion?.source == .ai
        }
        XCTAssertTrue(
            suggestionReady,
            "No validated AI proposal for \(testCase.id) via \(inputPath); diagnostics="
                + diagnostics.events.map {
                    "\($0.owner.rawValue)#\($0.token):\($0.reason.rawValue)"
                }.joined(separator: ",")
        )
        let suggestion = try XCTUnwrap(acceptedSuggestion ?? textView.flowSuggestion)
        XCTAssertEqual(suggestion.source, .ai)
        XCTAssertEqual(suggestion.acceptance, .reviewOnly)
        XCTAssertEqual(suggestion.edits, expectedEdits)
        XCTAssertEqual(suggestion.correctedSentence, candidate)
        let terminalEvent = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .sentenceRepair,
            reason: .visibleAIReviewOnlyRepair
        )
        XCTAssertLessThanOrEqual(
            terminalEvent?.elapsedMilliseconds ?? .max,
            4_000,
            "AI repair exceeded the corpus latency budget for \(testCase.id)"
        )

        let expectedDocument = NSMutableString(string: triggeredDocument)
        guard suggestion.sentenceRange.location >= 0,
              NSMaxRange(suggestion.sentenceRange) <= expectedDocument.length
        else {
            XCTFail(
                "Suggestion range \(suggestion.sentenceRange) escaped the frozen document "
                    + "for \(testCase.id)"
            )
            return .rejected
        }
        XCTAssertEqual(
            (triggeredDocument as NSString).substring(with: suggestion.sentenceRange),
            suggestion.originalSentence,
            "The proposal no longer owns the exact frozen sentence for \(testCase.id)"
        )
        expectedDocument.replaceCharacters(
            in: suggestion.sentenceRange,
            with: candidate
        )
        let acceptedDocument = expectedDocument as String
        textView.undoManager?.removeAllActions()
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.isFlowReviewPreviewShown)
        XCTAssertEqual(textView.string, triggeredDocument)
        XCTAssertEqual(box.value, triggeredDocument)
        await replaceFrozenReviewSuggestion(
            suggestion,
            expectedDocument: acceptedDocument,
            originalDocument: triggeredDocument,
            acceptanceCount: acceptanceCount,
            box: box,
            textView: textView,
            window: window,
            testCaseID: testCase.id
        )
        return .review
    }

    func replaceFrozenReviewSuggestion(
        _ suggestion: EditorFlowSuggestion,
        expectedDocument: String,
        originalDocument: String,
        acceptanceCount: EditorIntBox,
        box: EditorTextBox,
        textView: MarkdownNSTextView,
        window: NSWindow,
        testCaseID: String
    ) async {
        let reviewShown = await waitUntil { textView.isFlowReviewPreviewShown }
        XCTAssertTrue(reviewShown, "Inline review did not appear for \(testCaseID)")
        XCTAssertTrue(textView.hasRenderedFlowSuggestion(suggestion))
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        XCTAssertEqual(acceptanceCount.value, 0)
        XCTAssertEqual(textView.string, originalDocument)
        XCTAssertEqual(box.value, originalDocument)
        textView.keyDown(with: try! XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        let applied = await waitUntil {
            acceptanceCount.value == 1 && textView.string == expectedDocument
        }
        XCTAssertTrue(applied, "Inline review did not apply \(testCaseID)")
        XCTAssertEqual(box.value, expectedDocument)

        XCTAssertFalse(
            textView.confirmFlowReviewSuggestionForTesting(),
            "Dismissed inline review accepted twice for \(testCaseID)"
        )
        await nextMainRunLoopTurn()
        XCTAssertEqual(acceptanceCount.value, 1, "Review applied twice for \(testCaseID)")
        XCTAssertEqual(textView.string, expectedDocument)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, originalDocument, "Review undo failed for \(testCaseID)")
        XCTAssertEqual(box.value, originalDocument)
        textView.undoManager?.redo()
        XCTAssertEqual(textView.string, expectedDocument, "Review redo failed for \(testCaseID)")
        XCTAssertEqual(box.value, expectedDocument)
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: (expectedDocument as NSString).length, length: 0),
            "Review redo caret mismatch for \(testCaseID)"
        )
    }

    func runFrozenCleanCorpusCase(
        _ testCase: FlowWritingRepairCase,
        inputPath: FrozenCorpusInputPath
    ) async throws {
        let box = EditorTextBox("")
        let diagnostics = FlowDiagnosticEventBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], self.englishOrthography())
            },
            flowCheckDelayNanoseconds: frozenCorpusFlowCheckDelay(for: inputPath)
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: ""
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false
        )
        let sourceMode = frozenSourceMode(for: testCase)
        textView.flowSourceMode = sourceMode
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: sourceMode, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(
            rangesReady,
            "Protected ranges did not settle for \(testCase.id)"
        )

        let triggeredDocument = try await enterFrozenCorpusCase(
            testCase,
            inputPath: inputPath,
            textView: textView,
            window: window,
            diagnostics: diagnostics
        )
        let plan = try XCTUnwrap(EditorFlowCheckPlanner.plan(
            in: triggeredDocument,
            selectedRange: textView.selectedRange()
        ))
        let expectedReason: EditorFlowTerminalReason = plan.coversWholeCurrentSentence
            ? .clean
            : .unresolvedAppleResult
        let terminated = await waitUntil(timeout: 3) {
            diagnostics.events.contains {
                $0.owner == .sentenceRepair && $0.reason == expectedReason
            }
        }
        XCTAssertTrue(
            terminated,
            "Clean corpus attempt did not terminate for \(testCase.id) via \(inputPath)"
        )
        _ = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .sentenceRepair,
            reason: expectedReason
        )
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, triggeredDocument)
        XCTAssertEqual(box.value, triggeredDocument)
    }

    func runFrozenProtectedCorpusCase(
        _ testCase: FlowWritingRepairCase,
        inputPath: FrozenCorpusInputPath
    ) async throws {
        let box = EditorTextBox("")
        let diagnostics = FlowDiagnosticEventBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                let results = self.corpusProtectedResults(in: checkedText)
                completion(results, self.englishOrthography())
            },
            flowCheckDelayNanoseconds: frozenCorpusFlowCheckDelay(for: inputPath)
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: ""
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false
        )
        let sourceMode = frozenSourceMode(for: testCase)
        textView.flowSourceMode = sourceMode
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: sourceMode, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(
            rangesReady,
            "Protected ranges did not settle for \(testCase.id)"
        )

        let triggeredDocument = try await enterFrozenCorpusCase(
            testCase,
            inputPath: inputPath,
            textView: textView,
            window: window,
            diagnostics: diagnostics
        )
        let terminated = await waitUntil(timeout: 3) {
            diagnostics.events.contains {
                $0.owner == .sentenceRepair
                    && ($0.reason == .protected || $0.reason == .clean)
            }
        }
        XCTAssertTrue(
            terminated,
            "Protected corpus attempt did not terminate for \(testCase.id) via \(inputPath)"
        )
        let reason = diagnostics.events.first(where: {
            $0.owner == .sentenceRepair && ($0.reason == .protected || $0.reason == .clean)
        })?.reason ?? .clean
        _ = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .sentenceRepair,
            reason: reason
        )
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, triggeredDocument)
        XCTAssertEqual(box.value, triggeredDocument)
        for fragment in testCase.protectedFragments {
            XCTAssertTrue(
                textView.string.contains(fragment),
                "Protected fragment changed in \(testCase.id): \(fragment)"
            )
        }
    }

    func enterFrozenCorpusCase(
        _ testCase: FlowWritingRepairCase,
        inputPath: FrozenCorpusInputPath,
        textView: MarkdownNSTextView,
        window: NSWindow,
        diagnostics: FlowDiagnosticEventBox
    ) async throws -> String {
        switch testCase.trigger {
        case let .punctuation(punctuation, trailingDelimiterCount):
            let characters = Array(testCase.input)
            let punctuationIndex = characters.count - trailingDelimiterCount - 1
            guard punctuationIndex >= 0,
                  characters[punctuationIndex] == punctuation
            else {
                XCTFail("Invalid punctuation trigger in frozen case \(testCase.id)")
                return textView.string
            }
            let prefix = String(characters[..<punctuationIndex])
            let trailingDelimiters = String(characters[(punctuationIndex + 1)...])
            await insertFrozenCorpusText(
                prefix,
                inputPath: inputPath,
                testCaseID: testCase.id,
                textView: textView,
                window: window
            )
            XCTAssertEqual(textView.string, prefix, "Prefix mismatch for \(testCase.id)")
            await nextMainRunLoopTurn()
            diagnostics.removeAll()
            textView.keyDown(with: try XCTUnwrap(corpusKeyEvent(
                for: punctuation,
                windowNumber: window.windowNumber
            )))
            for delimiter in trailingDelimiters {
                textView.keyDown(with: try XCTUnwrap(corpusKeyEvent(
                    for: delimiter,
                    windowNumber: window.windowNumber
                )))
            }
            let triggeredDocument = textView.string
            if triggeredDocument != testCase.input {
                print(
                    "FLOW_CORPUS_INPUT_MISMATCH case=\(testCase.id) "
                        + "expected=\(testCase.input.debugDescription) "
                        + "actual=\(triggeredDocument.debugDescription)"
                )
            }
            XCTAssertEqual(
                triggeredDocument,
                testCase.input,
                "Triggered document must exactly match the frozen input for \(testCase.id) via \(inputPath)"
            )
            return triggeredDocument

        case .returnKey:
            await insertFrozenCorpusText(
                testCase.input,
                inputPath: inputPath,
                testCaseID: testCase.id,
                textView: textView,
                window: window
            )
            XCTAssertEqual(textView.string, testCase.input, "Input mismatch for \(testCase.id)")
            await nextMainRunLoopTurn()
            diagnostics.removeAll()
            textView.keyDown(with: try XCTUnwrap(keyEvent(
                characters: "\r",
                modifiers: [],
                keyCode: 36,
                windowNumber: window.windowNumber
            )))
            let triggeredDocument = textView.string
            XCTAssertEqual(
                triggeredDocument,
                testCase.input + "\n",
                "Return-triggered document must exactly match the frozen input for \(testCase.id) via \(inputPath)"
            )
            return triggeredDocument
        }
    }

    func insertFrozenCorpusText(
        _ text: String,
        inputPath: FrozenCorpusInputPath,
        testCaseID: String,
        textView: MarkdownNSTextView,
        window: NSWindow
    ) async {
        switch inputPath {
        case .characterTyping:
            for character in text {
                let event = corpusKeyEvent(
                    for: character,
                    windowNumber: window.windowNumber
                )
                if let event {
                    textView.keyDown(with: event)
                } else {
                    print(
                        "FLOW_CORPUS_KEY_FALLBACK case=\(testCaseID) "
                            + "scalar=\(String(character).unicodeScalars.map(\.value))"
                    )
                    textView.insertText(
                        String(character),
                        replacementRange: textView.selectedRange()
                    )
                }
                // Hardware events arrive on distinct turns. Let AppKit finish
                // each real key event so queued text-system work cannot mutate
                // an earlier word after the frozen trigger snapshot is taken.
                await nextMainRunLoopTurn()
            }
        case .pasteboard:
            let pasteboard = NSPasteboard(
                name: NSPasteboard.Name("monknot-flow-corpus-\(UUID().uuidString)")
            )
            pasteboard.clearContents()
            pasteboard.declareTypes([.string], owner: nil)
            XCTAssertTrue(pasteboard.setString(text, forType: .string))
            XCTAssertTrue(window.makeFirstResponder(textView))
            XCTAssertTrue(window.firstResponder === textView)
            XCTAssertTrue(
                textView.readSelection(from: pasteboard, type: .string),
                "Pasteboard insertion failed for \(testCaseID)"
            )
            pasteboard.releaseGlobally()
        }
    }

    func corpusKeyEvent(
        for character: Character,
        windowNumber: Int
    ) -> NSEvent? {
        let text = String(character)
        let lowercased = text.lowercased()
        let keyCodes: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
            "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "\n": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
            "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            " ": 49, "`": 50,
        ]
        let shiftedKeyCodes: [String: UInt16] = [
            "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23,
            "+": 24, "(": 25, "&": 26, "_": 27, "*": 28, ")": 29,
            "}": 30, "{": 33, "\"": 39, ":": 41, "|": 42, "<": 43,
            "?": 44, ">": 47,
        ]
        let shiftedBaseCharacters: [String: String] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "^": "6", "%": "5",
            "+": "=", "(": "9", "&": "7", "_": "-", "*": "8", ")": "0",
            "}": "]", "{": "[", "\"": "'", ":": ";", "|": "\\", "<": ",",
            "?": "/", ">": ".",
        ]
        let modifiers: NSEvent.ModifierFlags
        let keyCode: UInt16
        let charactersIgnoringModifiers: String
        if text == "”" {
            modifiers = [.option, .shift]
            keyCode = 33
            charactersIgnoringModifiers = "["
        } else if text == "’" {
            modifiers = [.option, .shift]
            keyCode = 30
            charactersIgnoringModifiers = "]"
        } else if let shifted = shiftedKeyCodes[text] {
            modifiers = .shift
            keyCode = shifted
            charactersIgnoringModifiers = shiftedBaseCharacters[text] ?? lowercased
        } else if text != lowercased, let letter = keyCodes[lowercased] {
            modifiers = .shift
            keyCode = letter
            charactersIgnoringModifiers = lowercased
        } else {
            modifiers = []
            keyCode = keyCodes[text] ?? 0
            charactersIgnoringModifiers = text
        }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: text,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    func corpusReferenceSlice(
        for checkedText: String,
        in testCase: FlowWritingRepairCase
    ) -> String? {
        if checkedText == testCase.input { return testCase.referenceText }
        let checked = checkedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputSentences = sentenceSlices(in: testCase.input)
        let referenceSentences = sentenceSlices(in: testCase.referenceText)
        guard inputSentences.count == referenceSentences.count,
              let sentenceIndex = inputSentences.firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines) == checked
              })
        else { return nil }
        return referenceSentences[sentenceIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sentenceSlices(in text: String) -> [String] {
        var slices: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences]
        ) { substring, _, _, _ in
            if let substring { slices.append(substring) }
        }
        return slices
    }

    func corpusDifferenceRanges(
        in text: String,
        candidate: String
    ) -> [NSRange] {
        let originalCharacters = Array(text)
        let candidateCharacters = Array(candidate)
        let difference = candidateCharacters.difference(from: originalCharacters)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                removedOffsets.insert(offset)
            case let .insert(offset, _, _):
                insertedOffsets.insert(offset)
            }
        }
        guard !removedOffsets.isEmpty || !insertedOffsets.isEmpty else { return [] }

        let originalMatches = originalCharacters.indices.filter { !removedOffsets.contains($0) }
        let candidateMatches = candidateCharacters.indices.filter { !insertedOffsets.contains($0) }
        guard originalMatches.count == candidateMatches.count else { return [] }

        func utf16Offsets(_ characters: [Character]) -> [Int] {
            var offsets = [0]
            for character in characters {
                offsets.append(offsets.last! + String(character).utf16.count)
            }
            return offsets
        }
        let originalOffsets = utf16Offsets(originalCharacters)
        let matches = Array(zip(originalMatches, candidateMatches))
            + [(originalCharacters.count, candidateCharacters.count)]
        var previousOriginal = -1
        var previousCandidate = -1
        var rawRanges: [NSRange] = []
        for (currentOriginal, currentCandidate) in matches {
            let originalStart = previousOriginal + 1
            let candidateStart = previousCandidate + 1
            if originalStart < currentOriginal || candidateStart < currentCandidate {
                rawRanges.append(NSRange(
                    location: originalOffsets[originalStart],
                    length: originalOffsets[currentOriginal] - originalOffsets[originalStart]
                ))
            }
            previousOriginal = currentOriginal
            previousCandidate = currentCandidate
        }

        let sourceLength = (text as NSString).length
        let words = wordRanges(in: text)
        let expanded = rawRanges.compactMap { raw -> NSRange? in
            let touchedWords = words.filter { word in
                if raw.length == 0 {
                    return raw.location >= word.location && raw.location <= NSMaxRange(word)
                }
                return NSIntersectionRange(raw, word).length > 0
            }
            if let first = touchedWords.first, let last = touchedWords.last {
                return NSRange(
                    location: first.location,
                    length: NSMaxRange(last) - first.location
                )
            }
            guard sourceLength > 0 else { return nil }
            return NSRange(location: min(raw.location, sourceLength - 1), length: 1)
        }.sorted { $0.location < $1.location }

        return expanded.reduce(into: []) { ranges, range in
            if let last = ranges.last,
               NSIntersectionRange(last, range).length > 0 || last == range {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
    }

    func corpusDetectedIssues(
        in text: String,
        candidate: String,
        issueRanges: [NSRange],
        testCase: FlowWritingRepairCase
    ) -> [EditorFlowDetectedIssue] {
        let permitsSpelling = testCase.mutations.contains(.spelling)
            || testCase.mutations.contains(.adjacentTransposition)
        let source = text as NSString
        let sourceWords = wordRanges(in: text)
        let candidateSource = candidate as NSString
        let candidateWords = wordRanges(in: candidate).map {
            candidateSource.substring(with: $0)
        }
        let duplicateRun = testCase.mutations.contains(.duplicatedWord)
            ? adjacentDuplicateWordRange(in: text)
            : nil
        var normalizedIssueRanges = issueRanges
        if let duplicateRun {
            normalizedIssueRanges = issueRanges.flatMap { range -> [NSRange] in
                guard NSIntersectionRange(range, duplicateRun).length > 0 else {
                    return [range]
                }
                return sourceWords.filter { word in
                    NSIntersectionRange(word, range).length > 0
                        && NSIntersectionRange(word, duplicateRun).length == 0
                }
            }
            // A real duplicate-word grammar detail spans both adjacent tokens.
            // Keep any separate issue-backed inflection in the same diff gap.
            normalizedIssueRanges.append(duplicateRun)
        }
        if testCase.mutations.contains(.runOnClause),
           let runOnRange = preciseRunOnGrammarRange(
               in: text,
               candidate: candidate,
               issueRanges: normalizedIssueRanges
           ) {
            normalizedIssueRanges.append(runOnRange)
        }
        return normalizedIssueRanges.map { range in
            let touchedWords = sourceWords.filter {
                NSIntersectionRange($0, range).length > 0
            }
            let isSpelling = permitsSpelling
                && touchedWords.count == 1
                && candidateWords.contains { candidateWord in
                    corpusLooksLikeSpellingRepair(
                        source.substring(with: touchedWords[0]),
                        candidateWord
                    )
                }
            return EditorFlowDetectedIssue(
                range: range,
                kind: isSpelling ? .spelling : .grammar,
                hasPreciseRange: true
            )
        }
    }

    func preciseRunOnGrammarRange(
        in text: String,
        candidate: String,
        issueRanges: [NSRange]
    ) -> NSRange? {
        let subjects: Set<String> = ["he", "i", "it", "she", "they", "we", "you"]
        let source = text as NSString
        let sourceWords = wordRanges(in: text)
        let candidateSource = candidate as NSString
        let sourceSubjects = sourceWords.map { source.substring(with: $0).lowercased() }
            .filter(subjects.contains)
        let candidateSubjects = wordRanges(in: candidate)
            .map { candidateSource.substring(with: $0).lowercased() }
            .filter(subjects.contains)
        guard candidateSubjects.count == sourceSubjects.count + 1 else { return nil }

        let connectors: Set<String> = ["and", "because", "but", "so", "while", "yet"]
        let connectorIndices = sourceWords.indices.filter {
            connectors.contains(source.substring(with: sourceWords[$0]).lowercased())
        }
        guard let connectorIndex = connectorIndices.last(where: { index in
            guard index + 2 < sourceWords.count else { return false }
            let localTail = NSRange(
                location: sourceWords[index].location,
                length: NSMaxRange(sourceWords[index + 2]) - sourceWords[index].location
            )
            return issueRanges.contains { NSIntersectionRange($0, localTail).length > 0 }
        }) else { return nil }

        // Model the precise grammar detail a checker reports for a run-on
        // boundary: a short local clause window, never the full sentence.
        let firstIndex = max(sourceWords.startIndex, connectorIndex - 3)
        let lastIndex = min(sourceWords.index(before: sourceWords.endIndex), connectorIndex + 2)
        return NSRange(
            location: sourceWords[firstIndex].location,
            length: NSMaxRange(sourceWords[lastIndex]) - sourceWords[firstIndex].location
        )
    }

    func adjacentDuplicateWordRange(in text: String) -> NSRange? {
        let source = text as NSString
        let words = wordRanges(in: text)
        guard words.count > 1 else { return nil }
        for index in 0..<(words.count - 1) {
            let first = words[index]
            let second = words[index + 1]
            guard source.substring(with: first).caseInsensitiveCompare(
                source.substring(with: second)
            ) == .orderedSame else { continue }
            let gap = NSRange(
                location: NSMaxRange(first),
                length: second.location - NSMaxRange(first)
            )
            guard source.substring(with: gap)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else { continue }
            return NSRange(
                location: first.location,
                length: NSMaxRange(second) - first.location
            )
        }
        return nil
    }

    func corpusCheckingResults(
        in text: String,
        detectedIssues: [EditorFlowDetectedIssue]
    ) -> [NSTextCheckingResult] {
        guard !detectedIssues.isEmpty else { return [] }
        var results = detectedIssues.compactMap { issue -> NSTextCheckingResult? in
            guard issue.kind == .spelling else { return nil }
            return NSTextCheckingResult.correctionCheckingResult(
                range: issue.range,
                replacementString: ""
            )
        }
        let grammarRanges = detectedIssues.filter { $0.kind == .grammar }.map(\.range)
        guard !grammarRanges.isEmpty else { return results }
        let sourceLength = (text as NSString).length
        results.append(NSTextCheckingResult.grammarCheckingResult(
            range: NSRange(location: 0, length: sourceLength),
            details: grammarRanges.map { range in
                [
                    NSGrammarRange: NSValue(range: range),
                    NSGrammarCorrections: [String](),
                ]
            }
        ))
        return results
    }

    func corpusLooksLikeSpellingRepair(
        _ original: String,
        _ replacement: String
    ) -> Bool {
        let left = Array(original.lowercased().filter { $0.isLetter || $0.isNumber })
        let right = Array(replacement.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !left.isEmpty, !right.isEmpty else { return false }
        let maximumLength = max(left.count, right.count)
        let allowedDistance = maximumLength >= 7
            ? 4
            : min(3, max(1, Int(ceil(Double(maximumLength) * 0.45))))
        var remaining = right
        var sharedCount = 0
        for character in left {
            if let index = remaining.firstIndex(of: character) {
                sharedCount += 1
                remaining.remove(at: index)
            }
        }
        return abs(left.count - right.count) <= allowedDistance
            && sharedCount * 5 >= maximumLength * 3
            && corpusEditDistance(left, right) <= allowedDistance
    }

    func corpusEditDistance(
        _ left: [Character],
        _ right: [Character]
    ) -> Int {
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous.last ?? 0
    }

    func corpusProtectedResults(in text: String) -> [NSTextCheckingResult] {
        let source = text as NSString
        for (typo, correction) in [("teh", "the"), ("retrun", "return")] {
            let range = source.range(of: typo)
            if range.location != NSNotFound {
                return [NSTextCheckingResult.correctionCheckingResult(
                    range: range,
                    replacementString: correction
                )]
            }
        }
        return []
    }

    func corpusCorrectionResults(
        in text: String,
        reference: String
    ) -> [NSTextCheckingResult] {
        guard text != reference else { return [] }
        let source = text as NSString
        let candidate = reference as NSString
        let sourceWords = wordRanges(in: text)
        let candidateWords = wordRanges(in: reference)
        guard !sourceWords.isEmpty, sourceWords.count == candidateWords.count else { return [] }

        return sourceWords.indices.compactMap { index in
            let sourceRange = NSRange(
                location: sourceWords[index].location,
                length: (index + 1 < sourceWords.count
                    ? sourceWords[index + 1].location
                    : source.length) - sourceWords[index].location
            )
            let candidateRange = NSRange(
                location: candidateWords[index].location,
                length: (index + 1 < candidateWords.count
                    ? candidateWords[index + 1].location
                    : candidate.length) - candidateWords[index].location
            )
            let originalSegment = source.substring(with: sourceRange)
            let correctedSegment = candidate.substring(with: candidateRange)
            guard originalSegment != correctedSegment else { return nil }
            return NSTextCheckingResult.correctionCheckingResult(
                range: sourceRange,
                replacementString: correctedSegment
            )
        }
    }

    func wordRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, _ in
            ranges.append(NSRange(range, in: text))
        }
        return ranges
    }

    func grammarResult(
        in text: String,
        target: String,
        corrections: [String]
    ) -> NSTextCheckingResult {
        let source = text as NSString
        let targetRange = source.range(of: target)
        precondition(targetRange.location != NSNotFound)
        return NSTextCheckingResult.grammarCheckingResult(
            range: NSRange(location: 0, length: source.length),
            details: [[
                NSGrammarRange: NSValue(range: targetRange),
                NSGrammarCorrections: corrections,
            ]]
        )
    }

    func englishOrthography() -> NSOrthography {
        NSOrthography(
            dominantScript: "Latn",
            languageMap: ["Latn": ["en"]]
        )
    }

    func prepareWritingTools(
        _ coordinator: MarkdownTextEditor.Coordinator,
        textView: MarkdownNSTextView
    ) async -> Bool {
        textView.flowSourceMode = .markdown
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        return await waitUntil { textView.flowWritingToolsReady }
    }

    func prepareProseCompletion(
        _ coordinator: MarkdownTextEditor.Coordinator,
        textView: MarkdownNSTextView,
        checksSpelling: Bool = false,
        inlinePredictions: Bool = true
    ) async -> Bool {
        let options = EditorTextCheckingOptions(
            checksSpelling: checksSpelling,
            checksGrammar: false,
            inlinePredictions: inlinePredictions,
            onDeviceProseCompletions: true
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        return await waitUntil { textView.flowWritingToolsReady }
    }

    func makeCoordinator(_ box: EditorTextBox) -> MarkdownTextEditor.Coordinator {
        MarkdownTextEditor.Coordinator(
            text: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            flowCheckDelayNanoseconds: nil
        )
    }

    func makeCoordinator(
        _ box: EditorTextBox,
        flowCheckingClient: EditorFlowCheckingClient,
        flowCheckDelayNanoseconds: UInt64? = nil
    ) -> MarkdownTextEditor.Coordinator {
        MarkdownTextEditor.Coordinator(
            text: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            flowCheckingClient: flowCheckingClient,
            flowCheckDelayNanoseconds: flowCheckDelayNanoseconds,
            flowFocusValidator: { _ in true }
        )
    }

    func makeCoordinator(
        _ box: EditorTextBox,
        flowCheckingClient: EditorFlowCheckingClient,
        sentenceRepair: FlowSentenceRepairService,
        flowCheckDelayNanoseconds: UInt64? = nil
    ) -> MarkdownTextEditor.Coordinator {
        MarkdownTextEditor.Coordinator(
            text: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            flowCheckingClient: flowCheckingClient,
            flowSentenceRepairService: sentenceRepair,
            flowCheckDelayNanoseconds: flowCheckDelayNanoseconds,
            flowFocusValidator: { _ in true }
        )
    }

    func makeCoordinator(
        _ box: EditorTextBox,
        flowCheckingClient: EditorFlowCheckingClient = EditorFlowCheckingClient {
            _, _, _, _, completion in completion([], nil)
        },
        proseCompletion: FlowProseCompletionService,
        proseCompletionDelayNanoseconds: UInt64 = 0,
        flowCheckDelayNanoseconds: UInt64? = nil
    ) -> MarkdownTextEditor.Coordinator {
        MarkdownTextEditor.Coordinator(
            text: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            flowCheckingClient: flowCheckingClient,
            flowProseCompletionService: proseCompletion,
            flowProseCompletionDelayNanoseconds: proseCompletionDelayNanoseconds,
            flowProseOfferDelayNanoseconds: 0,
            flowCheckDelayNanoseconds: flowCheckDelayNanoseconds,
            flowFocusValidator: { _ in true }
        )
    }

    func assertDeferredWritingToolsRequestDoesNotPresent(
        after mutation: DeferredWritingToolsMutation
    ) async {
        let source = "Plain prose"
        let box = EditorTextBox(source)
        let focus = EditorBoolBox(true)
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let presentationCount = EditorIntBox()
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            },
            flowFocusValidator: { _ in focus.value },
            writingToolsAvailability: { true },
            writingToolsPresenter: { _ in presentationCount.value += 1 }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        textView.flowSourceMode = .markdown
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let initialRangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(initialRangesReady)

        textView.insertText("!", replacementRange: textView.selectedRange())
        XCTAssertTrue(coordinator.requestWritingTools())
        let freshScanBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(freshScanBlocked)
        XCTAssertEqual(presentationCount.value, 0)

        switch mutation {
        case .selection:
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.textViewDidChangeSelection(Notification(
                name: NSTextView.didChangeSelectionNotification,
                object: textView
            ))
        case .text:
            textView.insertText("x", replacementRange: textView.selectedRange())
        case .focus:
            focus.value = false
            textView.flowSuggestionCancellationHandler?()
            // Returning before the blocked range scan completes must not revive
            // the request that belonged to the previous responder session.
            focus.value = true
        }

        provider.resumeBlockedCall()
        let rangesSettled = await waitUntil(timeout: 3) {
            textView.flowWritingToolsReady && provider.activeCallCount == 0
        }
        XCTAssertTrue(rangesSettled)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(presentationCount.value, 0)
    }

    func descendantViews(in root: NSView) -> [NSView] {
        root.subviews.flatMap { child in
            [child] + descendantViews(in: child)
        }
    }

    func nextMainRunLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    func holdTabUntilAccepted(
        in textView: MarkdownNSTextView,
        window: NSWindow,
        expectedText: String
    ) async throws -> Bool {
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        let accepted = await waitUntil(timeout: 1.5) {
            textView.string == expectedText && textView.flowProseSuggestion == nil
        }
        textView.keyUp(with: try XCTUnwrap(keyEvent(
            type: .keyUp,
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        return accepted
    }

    func renderFlowSuggestion(
        in textView: MarkdownNSTextView,
        window: NSWindow
    ) async {
        for _ in 0..<3 {
            await nextMainRunLoopTurn()
            window.makeFirstResponder(textView)
            textView.layoutSubtreeIfNeeded()
            if let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
            }
            textView.needsDisplay = true
            window.contentView?.needsDisplay = true
            window.contentView?.displayIfNeeded()
            textView.displayIfNeededIgnoringOpacity()
            let visibleRect = textView.visibleRect.intersection(textView.bounds)
            if !visibleRect.isEmpty,
               let representation = textView.bitmapImageRepForCachingDisplay(in: visibleRect) {
                textView.cacheDisplay(in: visibleRect, to: representation)
            }
            if let suggestion = textView.flowSuggestion,
               textView.hasRenderedFlowSuggestion(suggestion) {
                return
            }
            if let suggestion = textView.flowProseSuggestion,
               textView.canDirectlyAcceptFlowProseSuggestion(suggestion) {
                return
            }
        }
    }

    func assertSingleDiagnosticAttempt(
        _ diagnostics: FlowDiagnosticEventBox,
        owner: EditorFlowDiagnosticOwner,
        reason: EditorFlowTerminalReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> EditorFlowDiagnosticEvent? {
        guard let matched = diagnostics.events.first(where: {
            $0.owner == owner && $0.reason == reason
        }) else {
            XCTFail(
                "Missing \(owner.rawValue) diagnostic reason \(reason.rawValue)",
                file: file,
                line: line
            )
            return nil
        }

        let matchedOwner = matched.owner
        let matchedToken = matched.token
        await nextMainRunLoopTurn()
        await nextMainRunLoopTurn()

        let attemptEvents = diagnostics.events.filter {
            $0.owner == matchedOwner && $0.token == matchedToken
        }
        XCTAssertEqual(
            attemptEvents.count,
            1,
            "Diagnostic attempt \(matchedOwner.rawValue)#\(matchedToken) terminated more than once",
            file: file,
            line: line
        )
        XCTAssertEqual(
            attemptEvents.map(\.reason),
            [reason],
            "Diagnostic attempt \(matchedOwner.rawValue)#\(matchedToken) had the wrong sole reason",
            file: file,
            line: line
        )
        return matched
    }

    func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func makeHostedTextView(
        coordinator: MarkdownTextEditor.Coordinator,
        text: String,
        textView: MarkdownNSTextView? = nil
    ) -> (NSWindow, NSScrollView, MarkdownNSTextView) {
        let window = FlowTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        let textView = textView ?? MarkdownNSTextView(frame: scrollView.bounds)
        textView.frame = scrollView.bounds
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = coordinator
        textView.flowSuggestionAcceptanceHandler = { coordinator.acceptFlowSuggestion($0) }
        textView.flowProseSuggestionAcceptanceHandler = {
            coordinator.acceptFlowProseSuggestion($0, nextWordOnly: $1)
        }
        textView.flowSuggestionDismissalHandler = { coordinator.dismissFlowSuggestion() }
        textView.flowSuggestionCancellationHandler = { coordinator.cancelFlowForFocusLoss() }
        textView.flowProseSuggestionCancellationHandler = {
            coordinator.cancelProseCompletionForGeometryChange()
        }
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        scrollView.documentView = textView
        window.contentView = scrollView
        coordinator.textView = textView
        coordinator.documentID = "note.md"
        coordinator.externalTextDidChange()
        coordinator.attach(to: scrollView)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        return (window, scrollView, textView)
    }

    func flowSuggestion(
        coordinator: MarkdownTextEditor.Coordinator,
        textView: MarkdownNSTextView,
        checkedText: String,
        replacement: String,
        acceptance: EditorFlowSuggestionAcceptance = .direct
    ) -> EditorFlowSuggestion {
        let originalSentence = textView.string
        let editRange = (originalSentence as NSString).range(of: checkedText)
        let correctedSentence = (originalSentence as NSString).replacingCharacters(
            in: editRange,
            with: replacement
        )
        return EditorFlowSuggestion(
            documentID: coordinator.documentID!,
            revision: coordinator.revision,
            selectedRange: textView.selectedRange(),
            caretUTF16Offset: textView.selectedRange().location + textView.selectedRange().length,
            sentenceRange: NSRange(location: 0, length: (originalSentence as NSString).length),
            originalSentence: originalSentence,
            correctedSentence: correctedSentence,
            source: .deterministic,
            acceptance: acceptance,
            edits: [EditorFlowCorrectionEdit(
                range: editRange,
                originalText: checkedText,
                replacementText: replacement,
                kind: .spelling
            )]
        )
    }

    func dismantleHostedTextView(
        _ window: NSWindow,
        scrollView: NSScrollView,
        coordinator: MarkdownTextEditor.Coordinator
    ) {
        MarkdownTextEditor.dismantleNSView(scrollView, coordinator: coordinator)
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.orderOut(nil)
    }

    func testImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return image
    }

    func keyEvent(
        type: NSEvent.EventType = .keyDown,
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        isRepeat: Bool = false
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isRepeat,
            keyCode: keyCode
        )
    }
}

final class EditorTextBox {
    var value: String

    init(_ value: String) {
        self.value = value
    }
}

enum DeferredWritingToolsMutation {
    case selection
    case text
    case focus
}

enum FrozenCorpusInputPath: CustomStringConvertible {
    case characterTyping
    case pasteboard

    var description: String {
        switch self {
        case .characterTyping:
            return "character typing"
        case .pasteboard:
            return "pasteboard"
        }
    }
}

enum FrozenAICorpusOutcome: Equatable {
    case direct
    case review
    case rejected
}

final class EditorBoolBox {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

enum FrozenCorpusShard: CustomStringConvertible {
    case nonAI
    case ai(ClosedRange<Int>)

    var includesNonAI: Bool {
        if case .nonAI = self { return true }
        return false
    }

    func includesAI(id: String) -> Bool {
        guard case let .ai(range) = self,
              let suffix = id.split(separator: "-").last,
              let number = Int(suffix)
        else { return false }
        return range.contains(number)
    }

    var description: String {
        switch self {
        case .nonAI:
            return "nonAI"
        case let .ai(range):
            return String(format: "ai%03d-%03d", range.lowerBound, range.upperBound)
        }
    }
}

final class EditorIntBox {
    var value = 0
}

final class FlowDiagnosticEventBox {
    private(set) var events: [EditorFlowDiagnosticEvent] = []

    func append(_ event: EditorFlowDiagnosticEvent) {
        events.append(event)
    }

    func removeAll() {
        events.removeAll()
    }
}

final class FlowCorrectionEditsBox {
    private(set) var wasCaptured = false
    private(set) var value: [EditorFlowCorrectionEdit]?

    func capture(_ value: [EditorFlowCorrectionEdit]?) {
        wasCaptured = true
        self.value = value
    }
}

final class FlowProseCompletionSpy: @unchecked Sendable {
    let lock = NSLock()
    let available: Bool
    let result: String?
    let delayNanoseconds: UInt64
    let ignoresCancellation: Bool
    var storedRequests: [FlowProseCompletionRequest] = []

    init(
        isAvailable: Bool = true,
        result: String?,
        delayNanoseconds: UInt64 = 0,
        ignoresCancellation: Bool = false
    ) {
        available = isAvailable
        self.result = result
        self.delayNanoseconds = delayNanoseconds
        self.ignoresCancellation = ignoresCancellation
    }

    var requestCount: Int {
        lock.withLock { storedRequests.count }
    }

    var requests: [FlowProseCompletionRequest] {
        lock.withLock { storedRequests }
    }

    var service: FlowProseCompletionService {
        FlowProseCompletionService(
            isAvailable: { [available] _ in available },
            client: { [weak self] request, _ in
                guard let self else { return nil }
                self.lock.withLock { self.storedRequests.append(request) }
                if self.delayNanoseconds > 0 {
                    if self.ignoresCancellation {
                        try? await Task.sleep(nanoseconds: self.delayNanoseconds)
                    } else {
                        try await Task.sleep(nanoseconds: self.delayNanoseconds)
                    }
                }
                return self.result
            }
        )
    }
}

final class ImmediateSpellingFlowChecker {
    let original: String
    let replacement: String
    private(set) var requestCount = 0

    init(original: String, replacement: String) {
        self.original = original
        self.replacement = replacement
    }

    var client: EditorFlowCheckingClient {
        EditorFlowCheckingClient { [weak self] checkedText, _, _, _, completion in
            guard let self else {
                completion([], nil)
                return
            }
            requestCount += 1
            let range = (checkedText as NSString).range(of: original)
            guard range.location != NSNotFound else {
                completion([], nil)
                return
            }
            completion([
                NSTextCheckingResult.correctionCheckingResult(
                    range: range,
                    replacementString: replacement
                ),
            ], nil)
        }
    }
}

final class FlowCheckingRequestBox {
    var completion: EditorFlowCheckingClient.Completion?
    var onRequest: (() -> Void)?

    func capture(_ completion: @escaping EditorFlowCheckingClient.Completion) {
        self.completion = completion
        onRequest?()
    }
}

final class BlockingProtectedRangeProvider: @unchecked Sendable {
    let condition = NSCondition()
    var blockingCall: Int
    var storedCallCount = 0
    var storedActiveCallCount = 0
    var storedMaximumConcurrentCallCount = 0
    var callBlocked = false
    var blockedCallReleased = false

    init(blockingCall: Int = 1) {
        self.blockingCall = blockingCall
    }

    var callCount: Int {
        condition.withLock { storedCallCount }
    }

    var activeCallCount: Int {
        condition.withLock { storedActiveCallCount }
    }

    var maximumConcurrentCallCount: Int {
        condition.withLock { storedMaximumConcurrentCallCount }
    }

    var isCallBlocked: Bool {
        condition.withLock { callBlocked }
    }

    func blockNextCall() {
        condition.withLock {
            blockingCall = storedCallCount + 1
            callBlocked = false
            blockedCallReleased = false
        }
    }

    func protectedRanges(in text: String, mode: FlowSourceMode) -> [NSRange] {
        condition.lock()
        storedCallCount += 1
        storedActiveCallCount += 1
        storedMaximumConcurrentCallCount = max(
            storedMaximumConcurrentCallCount,
            storedActiveCallCount
        )
        let shouldBlock = storedCallCount == blockingCall
        if shouldBlock {
            callBlocked = true
            condition.broadcast()
            while !blockedCallReleased {
                condition.wait()
            }
        }
        condition.unlock()

        let ranges = FlowProtectedRangeService().protectedRanges(in: text, mode: mode)
        condition.withLock {
            storedActiveCallCount -= 1
            condition.broadcast()
        }
        return ranges
    }

    func resumeBlockedCall() {
        condition.withLock {
            blockedCallReleased = true
            condition.broadcast()
        }
    }
}

final class FlowChangeRecordingTextView: MarkdownNSTextView {
    struct ApprovedChange {
        let range: NSRange
        let replacement: String?
    }

    var approvedChanges: [ApprovedChange] = []

    override func shouldChangeText(
        in affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        approvedChanges.append(ApprovedChange(
            range: affectedCharRange,
            replacement: replacementString
        ))
        return super.shouldChangeText(
            in: affectedCharRange,
            replacementString: replacementString
        )
    }
}

final class FrozenCorpusTextView: MarkdownNSTextView {
    var rejectsSyntheticCantCorrection = false
    private(set) var rejectedSyntheticCantCorrectionCount = 0

    override func shouldChangeText(
        in affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        let source = string as NSString
        if rejectsSyntheticCantCorrection,
           affectedCharRange.location >= 0,
           NSMaxRange(affectedCharRange) <= source.length,
           source.substring(with: affectedCharRange).lowercased() == "cant",
           replacementString?.lowercased() == "can't" {
            rejectedSyntheticCantCorrectionCount += 1
            return false
        }
        return super.shouldChangeText(
            in: affectedCharRange,
            replacementString: replacementString
        )
    }
}

final class NativeCheckingRecordingTextView: MarkdownNSTextView {
    enum Event: Equatable {
        case clear(NSRange)
        case check(NSRange, NSTextCheckingTypes)
    }

    var nativeCheckingEvents: [Event] = []

    override func setSpellingState(_ value: Int, range charRange: NSRange) {
        if value == 0 {
            nativeCheckingEvents.append(.clear(charRange))
        }
        super.setSpellingState(value, range: charRange)
    }

    override func checkText(
        in range: NSRange,
        types checkingTypes: NSTextCheckingTypes,
        options: [NSSpellChecker.OptionKey: Any] = [:]
    ) {
        nativeCheckingEvents.append(.check(range, checkingTypes))
    }
}

final class FlowTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@available(macOS 15.0, *)
final class ActiveWritingToolsTextView: MarkdownNSTextView {
    override var isWritingToolsActive: Bool { true }
}
