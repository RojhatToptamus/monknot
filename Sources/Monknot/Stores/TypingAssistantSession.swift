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

    private static let enabledDefaultsKey = "Monknot.typingAssistant.enabled"
    private static let wordBoundaryDefaultsKey =
        "Monknot.typingAssistant.wordBoundaryEnabled"
    private static let grammarDefaultsKey =
        "Monknot.typingAssistant.grammarEnabled"
    private static let completionDefaultsKey =
        "Monknot.typingAssistant.completionEnabled"

    private let runtime: TypingAssistantRuntimeProviding
    private let defaults: UserDefaults
    private let pauseNanoseconds: UInt64
    private let modelBusyRetryNanoseconds: UInt64
    private let wordCorrector: TypingAssistanceWordBoundaryCorrector
    private var pendingTask: Task<Void, Never>?
    private var latestSnapshot: TypingAssistanceEditorSnapshot?
    private var requestGeneration = 0
    private var runtimeDiagnostics: LocalTypingAssistantRuntimeDiagnostics?
    private var staleResultCount = 0
    private var modelBusyRetryCount = 0
    private var shownSuggestionCount = 0
    private var acceptedSuggestionCount = 0
    private var dismissedSuggestionCount = 0
    private var automaticWordCorrectionCount = 0

    init(
        runtime: TypingAssistantRuntimeProviding = LocalTypingAssistantRuntime.shared,
        defaults: UserDefaults = .standard,
        pauseNanoseconds: UInt64 = 350_000_000,
        modelBusyRetryNanoseconds: UInt64 = 40_000_000,
        wordCorrector: TypingAssistanceWordBoundaryCorrector =
            TypingAssistanceWordBoundaryCorrector()
    ) {
        self.runtime = runtime
        self.defaults = defaults
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
        status = enabled ? .idle : .disabled
    }

    deinit {
        pendingTask?.cancel()
    }

    func editorDidChange(
        _ snapshot: TypingAssistanceEditorSnapshot,
        allowsGenerativeAssistance: Bool
    ) -> TypingAssistanceTextEdit? {
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
            automaticWordCorrectionCount += 1
            status = .idle
            return edit
        }

        guard allowsGenerativeAssistance,
              grammarSuggestionsEnabled,
              TypingAssistanceContextExtractor.correctionContext(
                for: snapshot
              ) != nil
        else {
            status = .idle
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
                generation: generation
            )
        }
    }

    func requestCompletion() {
        guard let latestSnapshot else { return }
        requestCompletion(for: latestSnapshot)
    }

    func dismissSuggestion() {
        if suggestion != nil {
            dismissedSuggestionCount += 1
        }
        suggestion = nil
        status = isEnabled ? .idle : .disabled
    }

    func suggestionApplicationFinished(accepted: Bool) {
        if accepted {
            acceptedSuggestionCount += 1
        } else {
            staleResultCount += 1
        }
        suggestion = nil
        status = isEnabled ? .idle : .disabled
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
        await receive(result, source: snapshot, generation: generation)
    }

    private func receive(
        _ result: LocalTypingAssistantRuntimeResult,
        source: TypingAssistanceEditorSnapshot,
        generation: Int
    ) async {
        runtimeDiagnostics = await runtime.diagnostics()
        latestRoute = result.route
        latestLatencyMilliseconds = result.latencyMilliseconds
        latestSuppressionReason = result.suppressionReason

        guard generation == requestGeneration,
              latestSnapshot == source
        else {
            staleResultCount += 1
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
}
