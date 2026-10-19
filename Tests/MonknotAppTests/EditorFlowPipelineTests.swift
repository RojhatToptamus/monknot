import AppKit
import MonknotCore
import XCTest
@testable import MonknotApp

/// `EditorFlowPipeline` with a stand-in editor in place of Source's text view or Preview's page:
/// protected ranges count only for the text they were scanned from, what holds Flow back keeps it
/// from asking the checker, and every check ends through the host with its reason and token.
@MainActor
final class EditorFlowPipelineTests: XCTestCase {
    private static let sentence = "We read the plan."

    func testProtectedRangesCountOnlyForTheTextTheyWereScannedFrom() async throws {
        let editor = StandInEditor()
        editor.type("Use `code` here")
        let codeSpan = NSRange(location: 4, length: 6)
        let pipeline = makePipeline(for: editor, protectedRanges: { _ in [codeSpan] })

        pipeline.scheduleProtectedRangesRefresh(delayNanoseconds: 0)
        XCTAssertNil(pipeline.currentProtectedRanges, "No ranges until the scan is in")
        try await waitUntil { pipeline.currentProtectedRanges != nil }
        XCTAssertEqual(pipeline.currentProtectedRanges, [codeSpan])
        XCTAssertEqual(editor.scannedRanges, [[codeSpan]])

        editor.type("Use `code` here!")
        XCTAssertNil(pipeline.currentProtectedRanges, "The ranges belong to the text before the edit")
        pipeline.adoptProtectedRanges([codeSpan])
        XCTAssertEqual(pipeline.currentProtectedRanges, [codeSpan], "Rebased ranges count for the text now")
    }

    func testAPausedEditorBlocksCompletionsAndAsksTheCheckerNothing() async throws {
        let editor = StandInEditor()
        editor.type(Self.sentence)
        let checker = CheckerStandIn()
        let pipeline = makePipeline(for: editor, checker: checker)
        pipeline.gate = .clear
        editor.flowHold = [.paused]

        pipeline.scheduleCheck()

        XCTAssertEqual(pipeline.gate, .blocked)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(checker.checkedTexts, [])
        XCTAssertFalse(
            editor.ended.contains { $0.owner == .sentenceRepair },
            "No check was scheduled to end"
        )
    }

    func testASuspendedEditorKeepsItsStateAndNeitherChecksNorScans() async throws {
        let editor = StandInEditor()
        editor.type(Self.sentence)
        let checker = CheckerStandIn()
        let scans = Counter()
        let pipeline = makePipeline(for: editor, checker: checker, protectedRanges: { _ in
            scans.increment()
            return []
        })
        pipeline.gate = .clear
        editor.flowHold = [.suspended]

        pipeline.scheduleCheck()
        pipeline.scheduleProtectedRangesRefresh(delayNanoseconds: 0)

        XCTAssertEqual(pipeline.gate, .clear, "Writing Tools or a missing page leave the gate as it was")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(checker.checkedTexts, [])
        XCTAssertEqual(scans.value, 0)
        XCTAssertNil(pipeline.currentProtectedRanges)
    }

    func testACleanSentenceIsCheckedOnceAndClearsTheGate() async throws {
        let editor = StandInEditor()
        editor.type(Self.sentence)
        let checker = CheckerStandIn()
        let pipeline = makePipeline(for: editor, checker: checker)
        pipeline.scheduleProtectedRangesRefresh(delayNanoseconds: 0)
        try await waitUntil { pipeline.currentProtectedRanges != nil }

        pipeline.scheduleCheck()
        try await waitUntil { pipeline.gate == .clear }

        XCTAssertEqual(checker.checkedTexts, [Self.sentence])
        XCTAssertEqual(editor.started, [StartedAttempt(owner: .sentenceRepair, token: 0)])
        XCTAssertEqual(editor.ended.last, EndedAttempt(owner: .sentenceRepair, reason: .clean, token: nil))
    }

    func testACheckWhoseSentenceChangedEndsStaleForItsOwnToken() async throws {
        let editor = StandInEditor()
        editor.type(Self.sentence)
        let checker = CheckerStandIn()
        let pipeline = makePipeline(for: editor, checker: checker, checkDelayNanoseconds: 30_000_000)

        pipeline.scheduleCheck()
        editor.type("We read the plans.")
        try await waitUntil { editor.ended.contains { $0.reason == .stale && $0.token != nil } }

        XCTAssertEqual(
            editor.ended.last,
            EndedAttempt(owner: .sentenceRepair, reason: .stale, token: 0)
        )
        XCTAssertEqual(checker.checkedTexts, [], "The old sentence never reaches the checker")
        XCTAssertEqual(pipeline.gate, .blocked)
    }

    // MARK: - Helpers

    private func makePipeline(
        for editor: StandInEditor,
        checker: CheckerStandIn = CheckerStandIn(),
        checkDelayNanoseconds: UInt64 = 0,
        protectedRanges: @escaping @Sendable (String) -> [NSRange] = { _ in [] }
    ) -> EditorFlowPipeline {
        let pipeline = EditorFlowPipeline(configuration: EditorFlowPipeline.Configuration(
            checkingClient: checker.client,
            protectedRangeProvider: { text, _ in protectedRanges(text) },
            checkDelayNanoseconds: checkDelayNanoseconds,
            protectedRangesDelayNanoseconds: 0
        ))
        pipeline.host = editor
        return pipeline
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("The condition did not hold in time", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private struct StartedAttempt: Equatable {
    let owner: EditorFlowDiagnosticOwner
    let token: Int
}

private struct EndedAttempt: Equatable {
    let owner: EditorFlowDiagnosticOwner
    let reason: EditorFlowTerminalReason
    let token: Int?
}

/// An editor with nothing on screen: it records what the pipeline asks it to show and how each
/// attempt ended.
@MainActor
private final class StandInEditor: EditorFlowPipelineHost {
    var flowDocumentID: String? = "note.md"
    var flowSourceMode: FlowSourceMode? = .markdown
    var flowOptions = EditorTextCheckingOptions(
        checksSpelling: true,
        checksGrammar: true,
        inlinePredictions: true,
        onDeviceProseCompletions: false
    )
    private(set) var flowText = ""
    private(set) var flowRevision = 0
    private(set) var flowSelection: NSRange?
    var flowSpellDocumentTag: Int { 0 }
    var flowHold: EditorFlowHold = []
    private(set) var scannedRanges: [[NSRange]] = []
    private(set) var started: [StartedAttempt] = []
    private(set) var ended: [EndedAttempt] = []

    var flowTextStamp: EditorFlowTextStamp? {
        EditorFlowTextStamp(revision: flowRevision, editCount: 0, mode: .markdown, storage: nil)
    }

    /// Replaces the text, caret at its end, as one edit.
    func type(_ text: String) {
        flowText = text
        flowRevision += 1
        flowSelection = NSRange(location: (text as NSString).length, length: 0)
    }

    func flowRepairIsVisible(_ suggestion: EditorFlowSuggestion) -> Bool { true }
    func flowPresentRepair(_ suggestion: EditorFlowSuggestion) -> Bool { true }
    func flowVisibleCompletion(_ continuation: String, at location: Int) -> String? { continuation }
    func flowPresentCompletion(_ suggestion: EditorFlowProseSuggestion, alreadyShown: Bool) {}
    func flowWithdrawCompletion() -> Bool { false }
    func flowDidScanProtectedRanges(_ ranges: [NSRange]) {
        scannedRanges.append(ranges)
    }
    func flowAvailabilityDidChange() {}

    func flowAttemptDidStart(_ owner: EditorFlowDiagnosticOwner, token: Int) {
        started.append(StartedAttempt(owner: owner, token: token))
    }

    func flowAttemptDidEnd(
        _ owner: EditorFlowDiagnosticOwner,
        reason: EditorFlowTerminalReason,
        token: Int?,
        refreshingAvailability: Bool
    ) {
        ended.append(EndedAttempt(owner: owner, reason: reason, token: token))
    }
}

/// Apple's checker, answering every sentence as clean in English.
private final class CheckerStandIn {
    private(set) var checkedTexts: [String] = []

    var client: EditorFlowCheckingClient {
        EditorFlowCheckingClient { [weak self] text, _, _, _, completion in
            self?.checkedTexts.append(text)
            completion([], NSOrthography(dominantScript: "Latn", languageMap: ["Latn": ["en"]]))
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
