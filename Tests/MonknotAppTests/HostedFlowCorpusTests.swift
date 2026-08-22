import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class HostedFlowCorpusTests: FlowEditorTestCase {
    func testFrozenCoordinatorNonAICorpusRunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .nonAI)
    }

    func testFrozenCoordinatorAI001Through005RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(1...5))
    }

    func testFrozenCoordinatorAI006Through008RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(6...8))
    }

    func testFrozenCoordinatorAI009RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(9...9))
    }

    func testFrozenCoordinatorAI010RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(10...10))
    }

    func testFrozenCoordinatorAI011Through013RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(11...13))
    }

    func testFrozenCoordinatorAI014Through015RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(14...15))
    }

    func testFrozenCoordinatorAI016Through018RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(16...18))
    }

    func testFrozenCoordinatorAI019Through020RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(19...20))
    }

    func testFrozenCoordinatorNonAICorpusRunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .nonAI)
    }

    func testFrozenCoordinatorAI001Through005RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(1...5))
    }

    func testFrozenCoordinatorAI006Through008RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(6...8))
    }

    func testFrozenCoordinatorAI009RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(9...9))
    }

    func testFrozenCoordinatorAI010RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(10...10))
    }

    func testFrozenCoordinatorAI011Through013RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(11...13))
    }

    func testFrozenCoordinatorAI014Through015RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(14...15))
    }

    func testFrozenCoordinatorAI016Through018RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(16...18))
    }

    func testFrozenCoordinatorAI019Through020RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(19...20))
    }

    func testFrozenConservativeAIReviewRunsThroughHostedCharacterTypingPath() async throws {
        let testCase = try XCTUnwrap(
            FlowWritingCorpus.repairCases.first { $0.id == "repair-ai-001" }
        )
        let outcome = try await runFrozenAICorpusCase(
            testCase,
            inputPath: .characterTyping
        )
        XCTAssertEqual(outcome, .review)
    }

    func testFrozenLongDeterministicRepairUsesPolicyAndExactUndoRedo() async throws {
        let testCase = try XCTUnwrap(
            FlowWritingCorpus.repairCases.first { $0.id == "repair-exact-024" }
        )
        try await runFrozenDeterministicCorpusCase(testCase, inputPath: .pasteboard)
    }

    func testFrozenQuotedHardWrapUsesRealPunctuationAndCloserKeyEvents() async throws {
        let testCase = try XCTUnwrap(
            FlowWritingCorpus.repairCases.first { $0.id == "repair-exact-022" }
        )
        try await runFrozenDeterministicCorpusCase(testCase, inputPath: .pasteboard)
    }

    func testFrozenProtectedReturnProducesExactlyOneTerminalAttempt() async throws {
        let testCase = try XCTUnwrap(
            FlowWritingCorpus.repairCases.first { $0.id == "repair-protected-002" }
        )
        try await runFrozenProtectedCorpusCase(testCase, inputPath: .pasteboard)
    }

    func testFrozenAICorpusFixturesPassWordIndependentReviewValidation() throws {
        let aiCases = FlowWritingCorpus.repairCases
            .filter { $0.expectation == .aiInvariant }
            .sorted { $0.id < $1.id }
        XCTAssertEqual(aiCases.count, 20)

        for testCase in aiCases {
            let candidate = testCase.conservativeCandidateFixture ?? testCase.referenceText
            let edits = EditorFlowAIRepairValidator.edits(
                originalSentence: testCase.input,
                candidateSentence: candidate
            )
            XCTAssertNotNil(edits, "Labeled fixture rejected: \(testCase.id)")
        }
    }
}
