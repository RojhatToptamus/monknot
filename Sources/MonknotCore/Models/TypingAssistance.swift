import Foundation

public enum TypingAssistanceRequestKind: String, Codable, Equatable, Sendable {
    case wordBoundary
    case grammar
    case completion
}

public struct TypingAssistanceEditorSnapshot: Equatable {
    public let documentID: String
    public let revision: Int
    public let text: String
    public let cursorUTF16Offset: Int
    public let selectionLength: Int
    public var selectionUTF16Location: Int {
        cursorUTF16Offset - selectionLength
    }

    public init(
        documentID: String,
        revision: Int,
        text: String,
        cursorUTF16Offset: Int,
        selectionLength: Int = 0
    ) {
        self.documentID = documentID
        self.revision = revision
        self.text = text
        self.cursorUTF16Offset = cursorUTF16Offset
        self.selectionLength = selectionLength
    }
}

public struct TypingAssistanceTextEdit: Equatable {
    public let range: NSRange
    public let replacementText: String

    public init(range: NSRange, replacementText: String) {
        self.range = range
        self.replacementText = replacementText
    }
}

public struct TypingAssistanceContext: Equatable {
    public let text: String
    public let range: NSRange

    public init(text: String, range: NSRange) {
        self.text = text
        self.range = range
    }
}

public struct TypingAssistanceSuggestion: Equatable, Identifiable {
    public let id: String
    public let requestKind: TypingAssistanceRequestKind
    public let sourceDocumentID: String
    public let sourceRevision: Int
    public let sourceText: String
    public let sourceCursorUTF16Offset: Int
    public let sourceSelectionUTF16Location: Int
    public let sourceSelectionLength: Int
    public let replacementRange: NSRange
    public let replacementText: String
    public let model: String
    public let latencyMilliseconds: Double

    public init(
        id: String = UUID().uuidString,
        requestKind: TypingAssistanceRequestKind,
        sourceDocumentID: String,
        sourceRevision: Int,
        sourceText: String,
        sourceCursorUTF16Offset: Int,
        sourceSelectionUTF16Location: Int,
        sourceSelectionLength: Int,
        replacementRange: NSRange,
        replacementText: String,
        model: String,
        latencyMilliseconds: Double
    ) {
        self.id = id
        self.requestKind = requestKind
        self.sourceDocumentID = sourceDocumentID
        self.sourceRevision = sourceRevision
        self.sourceText = sourceText
        self.sourceCursorUTF16Offset = sourceCursorUTF16Offset
        self.sourceSelectionUTF16Location = sourceSelectionUTF16Location
        self.sourceSelectionLength = sourceSelectionLength
        self.replacementRange = replacementRange
        self.replacementText = replacementText
        self.model = model
        self.latencyMilliseconds = latencyMilliseconds
    }
}

public enum TypingAssistanceApplicationRejection: String, Equatable {
    case documentChanged
    case revisionChanged
    case textChanged
    case cursorChanged
    case selectionChanged
    case invalidRange
}

public struct TypingAssistanceApplicationResult: Equatable {
    public let accepted: Bool
    public let text: String
    public let selectedRange: NSRange
    public let rejection: TypingAssistanceApplicationRejection?

    public init(
        accepted: Bool,
        text: String,
        selectedRange: NSRange,
        rejection: TypingAssistanceApplicationRejection?
    ) {
        self.accepted = accepted
        self.text = text
        self.selectedRange = selectedRange
        self.rejection = rejection
    }
}

public enum TypingAssistanceContentMode: String, Codable, Equatable {
    case prose
    case markdown
    case code
}

public enum TypingAssistanceEditorEventKind: String, Codable, Equatable {
    case textChange
    case wordBoundary
    case pause
    case completionRequest
    case focusLost
}

public struct TypingAssistanceEditorEvent: Equatable {
    public let id: String
    public let sequenceID: String
    public let snapshot: TypingAssistanceEditorSnapshot
    public let kind: TypingAssistanceEditorEventKind
    public let contentMode: TypingAssistanceContentMode
    public let idleMilliseconds: Int
    public let interKeyMilliseconds: Int?

    public init(
        id: String = UUID().uuidString,
        sequenceID: String,
        snapshot: TypingAssistanceEditorSnapshot,
        kind: TypingAssistanceEditorEventKind,
        contentMode: TypingAssistanceContentMode,
        idleMilliseconds: Int = 0,
        interKeyMilliseconds: Int? = nil
    ) {
        self.id = id
        self.sequenceID = sequenceID
        self.snapshot = snapshot
        self.kind = kind
        self.contentMode = contentMode
        self.idleMilliseconds = idleMilliseconds
        self.interKeyMilliseconds = interKeyMilliseconds
    }
}

public enum TypingAssistanceScheduleIntent: String, Codable, Equatable {
    case silent
    case wordBoundaryCorrection
    case pauseGrammar
    case completion
}

public struct TypingAssistanceScheduleDecision: Equatable {
    public let intent: TypingAssistanceScheduleIntent
    public let reason: String
    public let cancelPending: Bool
    public let modelCallAllowed: Bool
    public let automaticApplicationAllowed: Bool
    public let visibleSuggestionAllowed: Bool
    public let editorTextUnchanged: Bool

    public init(
        intent: TypingAssistanceScheduleIntent,
        reason: String,
        cancelPending: Bool,
        modelCallAllowed: Bool,
        automaticApplicationAllowed: Bool,
        visibleSuggestionAllowed: Bool,
        editorTextUnchanged: Bool = true
    ) {
        self.intent = intent
        self.reason = reason
        self.cancelPending = cancelPending
        self.modelCallAllowed = modelCallAllowed
        self.automaticApplicationAllowed = automaticApplicationAllowed
        self.visibleSuggestionAllowed = visibleSuggestionAllowed
        self.editorTextUnchanged = editorTextUnchanged
    }
}
