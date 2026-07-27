import Foundation

public enum TypingAssistanceTelemetryEventKind: String, Codable, Sendable {
    case editorChange
    case modelResult
    case suggestionAccepted
    case suggestionDismissed
    case automaticCorrection
    case staleResult
}

public enum TypingAssistanceInputCategory: String, Codable, Sendable {
    case short
    case normal
    case long20To50Words
    case over50Words
    case multiSentence

    public static func classify(_ text: String) -> Self {
        let words = text.split(whereSeparator: \.isWhitespace).count
        let sentenceEnds = text.reduce(into: 0) { count, character in
            if ".!?".contains(character) {
                count += 1
            }
        }
        if sentenceEnds > 1 {
            return .multiSentence
        }
        if words > 50 {
            return .over50Words
        }
        if words >= 20 {
            return .long20To50Words
        }
        if words <= 5 {
            return .short
        }
        return .normal
    }
}

public struct TypingAssistanceTelemetryEvent: Codable, Equatable, Sendable {
    public static let schemaVersion = "monknot-flow-telemetry-1.0"

    public let schemaVersion: String
    public let eventID: String
    public let participantID: String
    public let sessionID: String
    public let emittedAt: Date
    public let kind: TypingAssistanceTelemetryEventKind
    public let requestKind: TypingAssistanceRequestKind?
    public let inputCategory: TypingAssistanceInputCategory
    public let route: String?
    public let path: String
    public let timeoutResult: String
    public let fallbackResult: String
    public let dispatchMilliseconds: Double?
    public let modelLatencyMilliseconds: Double?
    public let suggestionShown: Bool
    public let automaticApplication: Bool
    public let accepted: Bool
    public let staleCancellation: Bool
    public let editorTextUnchanged: Bool
    public let fabricatedCorrectionCount: Int
    public let configuredMaxModelConcurrency: Int
    public let observedPeakModelConcurrency: Int?
    public let semanticBatchingUsed: Bool
    public let noteTextIncluded: Bool
    public let suggestionTextIncluded: Bool
    public let documentIdentityIncluded: Bool
    public let hiddenRegressionUsed: Bool
    public let trainingDataProduced: Bool

    public init(
        eventID: String = UUID().uuidString,
        participantID: String,
        sessionID: String,
        emittedAt: Date = Date(),
        kind: TypingAssistanceTelemetryEventKind,
        requestKind: TypingAssistanceRequestKind?,
        inputCategory: TypingAssistanceInputCategory,
        route: String?,
        path: String,
        timeoutResult: String,
        fallbackResult: String,
        dispatchMilliseconds: Double?,
        modelLatencyMilliseconds: Double?,
        suggestionShown: Bool,
        automaticApplication: Bool,
        accepted: Bool,
        staleCancellation: Bool,
        editorTextUnchanged: Bool,
        fabricatedCorrectionCount: Int = 0,
        configuredMaxModelConcurrency: Int = 1,
        observedPeakModelConcurrency: Int? = nil,
        semanticBatchingUsed: Bool = false,
        noteTextIncluded: Bool = false,
        suggestionTextIncluded: Bool = false,
        documentIdentityIncluded: Bool = false,
        hiddenRegressionUsed: Bool = false,
        trainingDataProduced: Bool = false
    ) {
        self.schemaVersion = Self.schemaVersion
        self.eventID = eventID
        self.participantID = participantID
        self.sessionID = sessionID
        self.emittedAt = emittedAt
        self.kind = kind
        self.requestKind = requestKind
        self.inputCategory = inputCategory
        self.route = route
        self.path = path
        self.timeoutResult = timeoutResult
        self.fallbackResult = fallbackResult
        self.dispatchMilliseconds = dispatchMilliseconds
        self.modelLatencyMilliseconds = modelLatencyMilliseconds
        self.suggestionShown = suggestionShown
        self.automaticApplication = automaticApplication
        self.accepted = accepted
        self.staleCancellation = staleCancellation
        self.editorTextUnchanged = editorTextUnchanged
        self.fabricatedCorrectionCount = fabricatedCorrectionCount
        self.configuredMaxModelConcurrency = configuredMaxModelConcurrency
        self.observedPeakModelConcurrency = observedPeakModelConcurrency
        self.semanticBatchingUsed = semanticBatchingUsed
        self.noteTextIncluded = noteTextIncluded
        self.suggestionTextIncluded = suggestionTextIncluded
        self.documentIdentityIncluded = documentIdentityIncluded
        self.hiddenRegressionUsed = hiddenRegressionUsed
        self.trainingDataProduced = trainingDataProduced
    }
}
