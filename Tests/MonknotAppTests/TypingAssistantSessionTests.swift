import Foundation
import XCTest
@testable import MonknotApp
@testable import MonknotCore

@MainActor
final class TypingAssistantSessionTests: XCTestCase {
    func testKnownBoundaryTypoReturnsImmediateLocalEdit() {
        let session = makeSession(runtime: FakeTypingAssistantRuntime())
        session.isEnabled = true
        session.wordBoundaryCorrectionEnabled = true
        let snapshot = makeSnapshot("teh ", revision: 1)

        let edit = session.editorDidChange(
            snapshot,
            allowsGenerativeAssistance: true
        )

        XCTAssertEqual(
            edit,
            TypingAssistanceTextEdit(
                range: NSRange(location: 0, length: 3),
                replacementText: "the"
            )
        )
        session.automaticWordCorrectionApplicationFinished(
            source: snapshot,
            accepted: true
        )
        XCTAssertEqual(session.diagnostics().automaticWordCorrectionCount, 1)
    }

    func testBoundaryAutoCorrectionRequiresExplicitOptIn() {
        let session = makeSession(runtime: FakeTypingAssistantRuntime())
        session.isEnabled = true

        let edit = session.editorDidChange(
            makeSnapshot("teh ", revision: 1),
            allowsGenerativeAssistance: false
        )

        XCTAssertNil(edit)
        XCTAssertEqual(session.diagnostics().automaticWordCorrectionCount, 0)
    }

    func testPauseGrammarSuppressesTechnicalContexts() async {
        let contexts = [
            "git status",
            "git checkout feature/local-fix",
            "npm test",
            "npm ci",
            "cargo build --release",
            "kubectl get pods",
            "swift test",
            "python3 scripts/check.py",
            "./scripts/check.sh --verbose",
            "C:\\Tools\\formatter.exe --check",
            "\"C:\\Program Files\\Formatter\\format.exe\" --check",
            "EDITOR=nano swift build",
            "render(value)",
            "result = render(value)",
            "/Users/example/notes/todo.md",
            "https://example.com/docs",
            "ssh://example.com/repository",
            "C:\\Users\\example\\notes\\todo.md",
            "$PROJECT_ROOT",
            "--verbose",
            "--verbose --force",
            "NODE_ENV=production",
            "`npm test`",
            "``npm `test` --silent``",
            "```\nnpm test\n```",
            "````swift\n```\nnpm test",
        ]

        for (revision, text) in contexts.enumerated() {
            let runtime = FakeTypingAssistantRuntime()
            let session = makeSession(runtime: runtime)
            session.isEnabled = true

            _ = session.editorDidChange(
                makeSnapshot(text, revision: revision),
                allowsGenerativeAssistance: true
            )
            try? await Task.sleep(nanoseconds: 5_000_000)
            let requestCount = await runtime.correctionRequestCount()

            XCTAssertEqual(
                requestCount,
                0,
                "Scheduled grammar for technical context: \(text)"
            )
            XCTAssertEqual(session.status, .idle)
        }
    }

    func testPauseGrammarKeepsOrdinaryToolMentionsEligible() async {
        let texts = [
            "please run `npm test` after teh meeting",
            "git status is useful for checking changes",
            "npm packages are cached locally",
            "cargo shipments arrive tomorrow",
            "docker containers simplify local testing",
            "swift makes local development convenient",
            "open source software helps this project",
        ]

        for (revision, text) in texts.enumerated() {
            let runtime = FakeTypingAssistantRuntime()
            let session = makeSession(runtime: runtime)
            session.isEnabled = true

            _ = session.editorDidChange(
                makeSnapshot(text, revision: revision),
                allowsGenerativeAssistance: true
            )
            try? await Task.sleep(nanoseconds: 20_000_000)
            let requestCount = await runtime.correctionRequestCount()

            XCTAssertEqual(
                requestCount,
                1,
                "Suppressed ordinary prose mentioning a tool: \(text)"
            )
        }
    }

    func testRapidTypingOnlyPresentsLatestSuggestion() async {
        let runtime = FakeTypingAssistantRuntime(delayNanoseconds: 10_000_000)
        let session = makeSession(runtime: runtime)
        session.isEnabled = true
        let first = makeSnapshot("first text", revision: 1)
        let second = makeSnapshot("second text", revision: 2)

        _ = session.editorDidChange(first, allowsGenerativeAssistance: true)
        _ = session.editorDidChange(second, allowsGenerativeAssistance: true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(session.suggestion?.sourceRevision, 2)
        XCTAssertEqual(session.suggestion?.sourceText, "second text")
        let requestCount = await runtime.correctionRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testSelectionChangeInvalidatesSuggestion() async {
        let runtime = FakeTypingAssistantRuntime()
        let session = makeSession(runtime: runtime)
        session.isEnabled = true
        let source = makeSnapshot("source text", revision: 1)

        _ = session.editorDidChange(source, allowsGenerativeAssistance: true)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNotNil(session.suggestion)

        session.selectionDidChange(
            TypingAssistanceEditorSnapshot(
                documentID: source.documentID,
                revision: source.revision,
                text: source.text,
                cursorUTF16Offset: 0,
                selectionLength: 0
            )
        )

        XCTAssertNil(session.suggestion)
    }

    func testSameCaretDifferentSelectionLengthInvalidatesSuggestion() async {
        let runtime = FakeTypingAssistantRuntime()
        let session = makeSession(runtime: runtime)
        session.isEnabled = true
        let source = makeSnapshot("source text", revision: 1)

        _ = session.editorDidChange(source, allowsGenerativeAssistance: true)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNotNil(session.suggestion)

        session.selectionDidChange(
            TypingAssistanceEditorSnapshot(
                documentID: source.documentID,
                revision: source.revision,
                text: source.text,
                cursorUTF16Offset: source.cursorUTF16Offset,
                selectionLength: 4
            )
        )

        XCTAssertNil(session.suggestion)
    }

    func testDuplicateSelectionNotificationKeepsPauseRequest() async {
        let runtime = FakeTypingAssistantRuntime()
        let session = makeSession(runtime: runtime)
        session.isEnabled = true
        let source = makeSnapshot("source text", revision: 1)

        _ = session.editorDidChange(source, allowsGenerativeAssistance: true)
        session.selectionDidChange(source)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let requestCount = await runtime.correctionRequestCount()

        XCTAssertEqual(requestCount, 1)
        XCTAssertNotNil(session.suggestion)
    }

    func testCompletionRemainsDisabledByDefault() {
        let session = makeSession(runtime: FakeTypingAssistantRuntime())
        session.isEnabled = true
        let snapshot = makeSnapshot("Please review ", revision: 1)

        session.requestCompletion(for: snapshot)

        XCTAssertNil(session.suggestion)
        XCTAssertEqual(session.status, .idle)
    }

    func testStaleRuntimeResultIsNotPresented() async {
        let runtime = FakeTypingAssistantRuntime(delayNanoseconds: 30_000_000)
        let session = makeSession(runtime: runtime)
        session.isEnabled = true
        let first = makeSnapshot("first text", revision: 1)

        _ = session.editorDidChange(first, allowsGenerativeAssistance: true)
        try? await Task.sleep(nanoseconds: 5_000_000)
        session.selectionDidChange(
            makeSnapshot("first text", revision: 1, cursor: 0)
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(session.suggestion)
        XCTAssertEqual(session.diagnostics().staleResultCount, 1)
    }

    func testLatestRequestRetriesTransientModelBusyState() async {
        let runtime = FakeTypingAssistantRuntime(busyResponses: 1)
        let session = makeSession(runtime: runtime)
        session.isEnabled = true
        let snapshot = makeSnapshot("latest text", revision: 1)

        _ = session.editorDidChange(
            snapshot,
            allowsGenerativeAssistance: true
        )
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(session.suggestion?.sourceText, "latest text")
        XCTAssertEqual(session.diagnostics().modelBusyRetryCount, 1)
        let requestCount = await runtime.correctionRequestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testTelemetryIsOptInAndContainsNoEditorText() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("flow.jsonl")
        let recorder = TypingAssistanceTelemetryRecorder(fileURL: fileURL)
        let session = makeSession(
            runtime: FakeTypingAssistantRuntime(),
            telemetryRecorder: recorder
        )
        session.isEnabled = true
        let sourceText = "private source phrase"

        _ = session.editorDidChange(
            makeSnapshot(sourceText, revision: 1),
            allowsGenerativeAssistance: true
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        session.dismissSuggestion()

        session.telemetryRecordingEnabled = true
        _ = session.editorDidChange(
            makeSnapshot(sourceText, revision: 2),
            allowsGenerativeAssistance: true
        )
        try? await Task.sleep(nanoseconds: 30_000_000)

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(contents.contains(sourceText))
        XCTAssertFalse(contents.contains("note.md"))
        XCTAssertTrue(contents.contains("\"noteTextIncluded\":false"))
        XCTAssertTrue(contents.contains("\"trainingDataProduced\":false"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try contents.split(separator: "\n").map {
            try decoder.decode(
                TypingAssistanceTelemetryEvent.self,
                from: Data($0.utf8)
            )
        }
        XCTAssertEqual(events.map(\.kind), [.editorChange, .modelResult])
        XCTAssertTrue(events.allSatisfy { !$0.staleCancellation })
        XCTAssertNil(events[0].observedPeakModelConcurrency)
        XCTAssertEqual(events[1].observedPeakModelConcurrency, 1)
    }

    private func makeSession(
        runtime: FakeTypingAssistantRuntime,
        telemetryRecorder: TypingAssistanceTelemetryRecorder =
            TypingAssistanceTelemetryRecorder()
    ) -> TypingAssistantSession {
        let suite = "TypingAssistantSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return TypingAssistantSession(
            runtime: runtime,
            defaults: defaults,
            telemetryRecorder: telemetryRecorder,
            pauseNanoseconds: 1_000_000,
            modelBusyRetryNanoseconds: 1_000_000
        )
    }

    private func makeSnapshot(
        _ text: String,
        revision: Int,
        cursor: Int? = nil
    ) -> TypingAssistanceEditorSnapshot {
        TypingAssistanceEditorSnapshot(
            documentID: "note.md",
            revision: revision,
            text: text,
            cursorUTF16Offset: cursor ?? (text as NSString).length
        )
    }
}

private actor FakeTypingAssistantRuntime: TypingAssistantRuntimeProviding {
    private let delayNanoseconds: UInt64
    private var busyResponses: Int
    private var correctionRequests = 0

    init(
        delayNanoseconds: UInt64 = 0,
        busyResponses: Int = 0
    ) {
        self.delayNanoseconds = delayNanoseconds
        self.busyResponses = busyResponses
    }

    func requestCorrection(
        snapshot: TypingAssistanceEditorSnapshot,
        context: TypingAssistanceContext
    ) async -> LocalTypingAssistantRuntimeResult {
        correctionRequests += 1
        if busyResponses > 0 {
            busyResponses -= 1
            return .noSuggestion(
                route: .modelBusy,
                latencyMilliseconds: 0
            )
        }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return LocalTypingAssistantRuntimeResult(
            route: .loadedForeground,
            suggestion: TypingAssistanceSuggestion(
                requestKind: .grammar,
                sourceDocumentID: snapshot.documentID,
                sourceRevision: snapshot.revision,
                sourceText: snapshot.text,
                sourceCursorUTF16Offset: snapshot.cursorUTF16Offset,
                sourceSelectionUTF16Location: snapshot.selectionUTF16Location,
                sourceSelectionLength: snapshot.selectionLength,
                replacementRange: context.range,
                replacementText: context.text.capitalized + ".",
                model: "fake",
                latencyMilliseconds: 1
            ),
            latencyMilliseconds: 1,
            suppressionReason: nil
        )
    }

    func requestCompletion(
        snapshot: TypingAssistanceEditorSnapshot,
        context: TypingAssistanceContext
    ) async -> LocalTypingAssistantRuntimeResult {
        .noSuggestion(
            route: .foregroundNoSuggestion,
            latencyMilliseconds: 1
        )
    }

    func diagnostics() async -> LocalTypingAssistantRuntimeDiagnostics {
        LocalTypingAssistantRuntimeDiagnostics(
            model: "fake",
            observedPeakModelConcurrency: 1,
            totalModelCalls: correctionRequests,
            foregroundTimeouts: 0,
            backgroundWarmups: 0,
            fallbackTextMutationCount: 0,
            fabricatedFallbackCorrectionCount: 0
        )
    }

    func correctionRequestCount() -> Int {
        correctionRequests
    }
}
