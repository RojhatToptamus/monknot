import Foundation
import MonknotCore

protocol TypingAssistantRuntimeProviding {
    func requestCorrection(
        snapshot: TypingAssistanceEditorSnapshot,
        context: TypingAssistanceContext
    ) async -> LocalTypingAssistantRuntimeResult

    func requestCompletion(
        snapshot: TypingAssistanceEditorSnapshot,
        context: TypingAssistanceContext
    ) async -> LocalTypingAssistantRuntimeResult

    func diagnostics() async -> LocalTypingAssistantRuntimeDiagnostics
}

extension LocalTypingAssistantRuntime: TypingAssistantRuntimeProviding {}

enum TypingAssistantSessionStatus: Equatable {
    case disabled
    case idle
    case waitingForPause
    case checking
    case suggestionReady
    case fallback(LocalTypingAssistantRoute)
}

struct TypingAssistantSessionDiagnostics: Equatable {
    let status: TypingAssistantSessionStatus
    let latestRoute: LocalTypingAssistantRoute?
    let latestLatencyMilliseconds: Double?
    let latestSuppressionReason: String?
    let staleResultCount: Int
    let modelBusyRetryCount: Int
    let shownSuggestionCount: Int
    let acceptedSuggestionCount: Int
    let dismissedSuggestionCount: Int
    let automaticWordCorrectionCount: Int
    let runtime: LocalTypingAssistantRuntimeDiagnostics?
}

@MainActor
final class TypingAssistantSession: ObservableObject {
    @Published private(set) var status: TypingAssistantSessionStatus
    @Published private(set) var suggestion: TypingAssistanceSuggestion?
    @Published private(set) var latestRoute: LocalTypingAssistantRoute?
    @Published private(set) var latestLatencyMilliseconds: Double?
    @Published private(set) var latestSuppressionReason: String?
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledDefaultsKey)
            if !isEnabled {
                invalidate()
                status = .disabled
            } else if status == .disabled {
                status = .idle
            }
        }
    }
    @Published var wordBoundaryCorrectionEnabled: Bool {
        didSet {
            defaults.set(
                wordBoundaryCorrectionEnabled,
                forKey: Self.wordBoundaryDefaultsKey
            )
        }
    }
    @Published var grammarSuggestionsEnabled: Bool {
        didSet {
            defaults.set(
                grammarSuggestionsEnabled,
                forKey: Self.grammarDefaultsKey
            )
            if !grammarSuggestionsEnabled {
                cancelPendingRequest()
            }
        }
    }
    @Published private(set) var phraseCompletionEnabled: Bool
    @Published var telemetryRecordingEnabled: Bool {
        didSet {
            defaults.set(
                telemetryRecordingEnabled,
                forKey: Self.telemetryRecordingDefaultsKey
            )
            if telemetryRecordingEnabled, participantID == nil {
                let identifier = UUID().uuidString
                participantID = identifier
                defaults.set(
                    identifier,
                    forKey: Self.telemetryParticipantDefaultsKey
                )
            }
        }
    }

    private static let enabledDefaultsKey = "Monknot.typingAssistant.enabled"
    private static let wordBoundaryDefaultsKey =
        "Monknot.typingAssistant.wordBoundaryEnabled"
    private static let grammarDefaultsKey =
        "Monknot.typingAssistant.grammarEnabled"
    private static let completionDefaultsKey =
        "Monknot.typingAssistant.completionEnabled"
    private static let telemetryRecordingDefaultsKey =
        "Monknot.typingAssistant.telemetryRecordingEnabled"
    private static let telemetryParticipantDefaultsKey =
        "Monknot.typingAssistant.telemetryParticipantID"

    private let runtime: TypingAssistantRuntimeProviding
    private let defaults: UserDefaults
    private let telemetryRecorder: TypingAssistanceTelemetryRecorder
    private let telemetrySessionID = UUID().uuidString
    private let pauseNanoseconds: UInt64
    private let modelBusyRetryNanoseconds: UInt64
    private let wordCorrector: TypingAssistanceWordBoundaryCorrector
    private var pendingTask: Task<Void, Never>?
    private var telemetryWriteTask: Task<Void, Never>?
    private var latestSnapshot: TypingAssistanceEditorSnapshot?
    private var requestGeneration = 0
    private var runtimeDiagnostics: LocalTypingAssistantRuntimeDiagnostics?
    private var staleResultCount = 0
    private var modelBusyRetryCount = 0
    private var shownSuggestionCount = 0
    private var acceptedSuggestionCount = 0
    private var dismissedSuggestionCount = 0
    private var automaticWordCorrectionCount = 0
    private var participantID: String?

    init(
        runtime: TypingAssistantRuntimeProviding = LocalTypingAssistantRuntime.shared,
        defaults: UserDefaults = .standard,
        telemetryRecorder: TypingAssistanceTelemetryRecorder =
            TypingAssistanceTelemetryRecorder(),
        pauseNanoseconds: UInt64 = 350_000_000,
        modelBusyRetryNanoseconds: UInt64 = 40_000_000,
        wordCorrector: TypingAssistanceWordBoundaryCorrector =
            TypingAssistanceWordBoundaryCorrector()
    ) {
        self.runtime = runtime
        self.defaults = defaults
        self.telemetryRecorder = telemetryRecorder
        self.pauseNanoseconds = pauseNanoseconds
        self.modelBusyRetryNanoseconds = modelBusyRetryNanoseconds
        self.wordCorrector = wordCorrector

        let enabled = defaults.object(forKey: Self.enabledDefaultsKey) == nil
            ? false
            : defaults.bool(forKey: Self.enabledDefaultsKey)
        isEnabled = enabled
        wordBoundaryCorrectionEnabled =
            defaults.object(forKey: Self.wordBoundaryDefaultsKey) == nil
            ? false
            : defaults.bool(forKey: Self.wordBoundaryDefaultsKey)
        grammarSuggestionsEnabled =
            defaults.object(forKey: Self.grammarDefaultsKey) == nil
            ? true
            : defaults.bool(forKey: Self.grammarDefaultsKey)
        phraseCompletionEnabled = false
        defaults.set(false, forKey: Self.completionDefaultsKey)
        telemetryRecordingEnabled = defaults.bool(
            forKey: Self.telemetryRecordingDefaultsKey
        )
        participantID = defaults.string(
            forKey: Self.telemetryParticipantDefaultsKey
        )
        status = enabled ? .idle : .disabled
        if telemetryRecordingEnabled, participantID == nil {
            let identifier = UUID().uuidString
            participantID = identifier
            defaults.set(
                identifier,
                forKey: Self.telemetryParticipantDefaultsKey
            )
        }
    }

    deinit {
        pendingTask?.cancel()
    }

    func editorDidChange(
        _ snapshot: TypingAssistanceEditorSnapshot,
        allowsGenerativeAssistance: Bool
    ) -> TypingAssistanceTextEdit? {
        let dispatchStarted = Date()
        let supersededWork = pendingTask != nil || suggestion != nil
        latestSnapshot = snapshot
        requestGeneration += 1
        pendingTask?.cancel()
        pendingTask = nil
        if let suggestion, !matchesCurrentSnapshot(suggestion) {
            self.suggestion = nil
        }

        guard isEnabled else {
            status = .disabled
            return nil
        }

        if allowsGenerativeAssistance,
           wordBoundaryCorrectionEnabled,
           let edit = wordCorrector.edit(for: snapshot) {
            status = .idle
            recordTelemetry(
                kind: .editorChange,
                inputText: snapshot.text,
                requestKind: .wordBoundary,
                result: nil,
                dispatchMilliseconds: elapsedMilliseconds(
                    since: dispatchStarted
                ),
                suggestionShown: false,
                automaticApplication: false,
                accepted: false,
                staleCancellation: supersededWork,
                editorTextUnchanged: true
            )
            return edit
        }

        guard allowsGenerativeAssistance,
              grammarSuggestionsEnabled,
              TypingAssistanceContextExtractor.correctionContext(
                for: snapshot
              ) != nil
        else {
            status = .idle
            recordTelemetry(
                kind: .editorChange,
                inputText: snapshot.text,
                requestKind: nil,
                result: nil,
                dispatchMilliseconds: elapsedMilliseconds(
                    since: dispatchStarted
                ),
                suggestionShown: false,
                automaticApplication: false,
                accepted: false,
                staleCancellation: supersededWork,
                editorTextUnchanged: true
            )
            return nil
        }

        status = .waitingForPause
        let generation = requestGeneration
        pendingTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.pauseNanoseconds ?? 0)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.requestGrammar(
                snapshot: snapshot,
                generation: generation
            )
        }
        recordTelemetry(
            kind: .editorChange,
            inputText: snapshot.text,
            requestKind: .grammar,
            result: nil,
            dispatchMilliseconds: elapsedMilliseconds(
                since: dispatchStarted
            ),
            suggestionShown: false,
            automaticApplication: false,
            accepted: false,
            staleCancellation: supersededWork,
            editorTextUnchanged: true
        )
        return nil
    }

    func selectionDidChange(_ snapshot: TypingAssistanceEditorSnapshot) {
        guard latestSnapshot != snapshot else { return }
        latestSnapshot = snapshot
        requestGeneration += 1
        pendingTask?.cancel()
        pendingTask = nil
        if let suggestion, !matchesCurrentSnapshot(suggestion) {
            self.suggestion = nil
        }
        status = isEnabled ? .idle : .disabled
    }

    func requestCompletion(for snapshot: TypingAssistanceEditorSnapshot) {
        latestSnapshot = snapshot
        requestGeneration += 1
        pendingTask?.cancel()
        pendingTask = nil
        suggestion = nil

        guard isEnabled, phraseCompletionEnabled,
              let context = TypingAssistanceContextExtractor.completionContext(
                for: snapshot
              )
        else {
            status = isEnabled ? .idle : .disabled
            return
        }

        let generation = requestGeneration
        status = .checking
        pendingTask = Task { [weak self] in
            guard let self else { return }
            let result = await runtime.requestCompletion(
                snapshot: snapshot,
                context: context
            )
            await receive(
                result,
                source: snapshot,
                generation: generation,
                requestKind: .completion
            )
        }
    }

    func requestCompletion() {
        guard let latestSnapshot else { return }
        requestCompletion(for: latestSnapshot)
    }

    func dismissSuggestion() {
        let dismissed = suggestion
        if dismissed != nil {
            dismissedSuggestionCount += 1
        }
        suggestion = nil
        status = isEnabled ? .idle : .disabled
        if let dismissed {
            recordTelemetry(
                kind: .suggestionDismissed,
                inputText: dismissed.sourceText,
                requestKind: dismissed.requestKind,
                result: nil,
                dispatchMilliseconds: nil,
                suggestionShown: true,
                automaticApplication: false,
                accepted: false,
                staleCancellation: false,
                editorTextUnchanged: true
            )
        }
    }

    func suggestionApplicationFinished(accepted: Bool) {
        let applied = suggestion
        if accepted {
            acceptedSuggestionCount += 1
        } else {
            staleResultCount += 1
        }
        suggestion = nil
        status = isEnabled ? .idle : .disabled
        if let applied {
            recordTelemetry(
                kind: .suggestionAccepted,
                inputText: applied.sourceText,
                requestKind: applied.requestKind,
                result: nil,
                dispatchMilliseconds: nil,
                suggestionShown: true,
                automaticApplication: false,
                accepted: accepted,
                staleCancellation: !accepted,
                editorTextUnchanged: !accepted
            )
        }
    }

    func automaticWordCorrectionApplicationFinished(
        source: TypingAssistanceEditorSnapshot,
        accepted: Bool
    ) {
        if accepted {
            automaticWordCorrectionCount += 1
        }
        recordTelemetry(
            kind: .automaticCorrection,
            inputText: source.text,
            requestKind: .wordBoundary,
            result: nil,
            dispatchMilliseconds: nil,
            suggestionShown: false,
            automaticApplication: accepted,
            accepted: accepted,
            staleCancellation: !accepted,
            editorTextUnchanged: !accepted
        )
    }

    func invalidate() {
        requestGeneration += 1
        pendingTask?.cancel()
        pendingTask = nil
        latestSnapshot = nil
        suggestion = nil
        status = isEnabled ? .idle : .disabled
    }

    func diagnostics() -> TypingAssistantSessionDiagnostics {
        TypingAssistantSessionDiagnostics(
            status: status,
            latestRoute: latestRoute,
            latestLatencyMilliseconds: latestLatencyMilliseconds,
            latestSuppressionReason: latestSuppressionReason,
            staleResultCount: staleResultCount,
            modelBusyRetryCount: modelBusyRetryCount,
            shownSuggestionCount: shownSuggestionCount,
            acceptedSuggestionCount: acceptedSuggestionCount,
            dismissedSuggestionCount: dismissedSuggestionCount,
            automaticWordCorrectionCount: automaticWordCorrectionCount,
            runtime: runtimeDiagnostics
        )
    }

    private func requestGrammar(
        snapshot: TypingAssistanceEditorSnapshot,
        generation: Int,
        retryAttempt: Int = 0
    ) async {
        guard generation == requestGeneration,
              latestSnapshot == snapshot,
              let context = TypingAssistanceContextExtractor.correctionContext(
                for: snapshot
              )
        else {
            return
        }
        status = .checking
        let result = await runtime.requestCorrection(
            snapshot: snapshot,
            context: context
        )
        if result.route == .modelBusy, retryAttempt < 4 {
            modelBusyRetryCount += 1
            do {
                try await Task.sleep(
                    nanoseconds: modelBusyRetryNanoseconds
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  generation == requestGeneration,
                  latestSnapshot == snapshot
            else {
                return
            }
            await requestGrammar(
                snapshot: snapshot,
                generation: generation,
                retryAttempt: retryAttempt + 1
            )
            return
        }
        await receive(
            result,
            source: snapshot,
            generation: generation,
            requestKind: .grammar
        )
    }

    private func receive(
        _ result: LocalTypingAssistantRuntimeResult,
        source: TypingAssistanceEditorSnapshot,
        generation: Int,
        requestKind: TypingAssistanceRequestKind
    ) async {
        runtimeDiagnostics = await runtime.diagnostics()
        latestRoute = result.route
        latestLatencyMilliseconds = result.latencyMilliseconds
        latestSuppressionReason = result.suppressionReason
        if generation == requestGeneration {
            pendingTask = nil
        }

        guard generation == requestGeneration,
              latestSnapshot == source
        else {
            staleResultCount += 1
            recordTelemetry(
                kind: .staleResult,
                inputText: source.text,
                requestKind: requestKind,
                result: result,
                dispatchMilliseconds: nil,
                suggestionShown: false,
                automaticApplication: false,
                accepted: false,
                staleCancellation: true,
                editorTextUnchanged: true
            )
            return
        }

        suggestion = result.suggestion
        if result.suggestion != nil {
            shownSuggestionCount += 1
            status = .suggestionReady
        } else if result.route == .foregroundNoSuggestion {
            status = .idle
        } else {
            status = .fallback(result.route)
        }
        recordTelemetry(
            kind: .modelResult,
            inputText: requestKind == .completion
                ? TypingAssistanceContextExtractor.completionContext(
                    for: source
                )?.text ?? source.text
                : TypingAssistanceContextExtractor.correctionContext(
                    for: source
                )?.text ?? source.text,
            requestKind: requestKind,
            result: result,
            dispatchMilliseconds: nil,
            suggestionShown: result.suggestion != nil,
            automaticApplication: false,
            accepted: false,
            staleCancellation: false,
            editorTextUnchanged: true
        )
    }

    private func matchesCurrentSnapshot(
        _ suggestion: TypingAssistanceSuggestion
    ) -> Bool {
        guard let latestSnapshot else { return false }
        return suggestion.sourceDocumentID == latestSnapshot.documentID
            && suggestion.sourceRevision == latestSnapshot.revision
            && suggestion.sourceText == latestSnapshot.text
            && suggestion.sourceCursorUTF16Offset
                == latestSnapshot.cursorUTF16Offset
    }

    private func cancelPendingRequest() {
        requestGeneration += 1
        pendingTask?.cancel()
        pendingTask = nil
        suggestion = nil
        status = isEnabled ? .idle : .disabled
    }

    var telemetryFileURL: URL {
        telemetryRecorder.fileURL
    }

    private func recordTelemetry(
        kind: TypingAssistanceTelemetryEventKind,
        inputText: String,
        requestKind: TypingAssistanceRequestKind?,
        result: LocalTypingAssistantRuntimeResult?,
        dispatchMilliseconds: Double?,
        suggestionShown: Bool,
        automaticApplication: Bool,
        accepted: Bool,
        staleCancellation: Bool,
        editorTextUnchanged: Bool
    ) {
        guard telemetryRecordingEnabled, let participantID else { return }
        let route = result?.route
        let event = TypingAssistanceTelemetryEvent(
            participantID: participantID,
            sessionID: telemetrySessionID,
            kind: kind,
            requestKind: requestKind,
            inputCategory: TypingAssistanceInputCategory.classify(inputText),
            route: route?.rawValue,
            path: telemetryPath(for: route),
            timeoutResult: telemetryTimeout(for: route),
            fallbackResult: telemetryFallback(for: route),
            dispatchMilliseconds: dispatchMilliseconds,
            modelLatencyMilliseconds: result?.latencyMilliseconds,
            suggestionShown: suggestionShown,
            automaticApplication: automaticApplication,
            accepted: accepted,
            staleCancellation: staleCancellation,
            editorTextUnchanged: editorTextUnchanged,
            observedPeakModelConcurrency: result == nil
                ? nil
                : runtimeDiagnostics?.observedPeakModelConcurrency
        )
        let previousWrite = telemetryWriteTask
        let recorder = telemetryRecorder
        telemetryWriteTask = Task {
            await previousWrite?.value
            try? await recorder.append(event)
        }
    }

    private func telemetryPath(
        for route: LocalTypingAssistantRoute?
    ) -> String {
        switch route {
        case .unloadedBackgroundWarmup, .probeFailure:
            return "background"
        case nil:
            return "none"
        default:
            return "foreground"
        }
    }

    private func telemetryTimeout(
        for route: LocalTypingAssistantRoute?
    ) -> String {
        route == .foregroundTimeout ? "foregroundTimeout" : "notTimedOut"
    }

    private func telemetryFallback(
        for route: LocalTypingAssistantRoute?
    ) -> String {
        switch route {
        case .loadedForeground:
            return "notFallback"
        case nil:
            return "notFallback"
        default:
            return "noSuggestion"
        }
    }

    private func elapsedMilliseconds(since started: Date) -> Double {
        Date().timeIntervalSince(started) * 1_000
    }
}
