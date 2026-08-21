import Foundation

/// Frozen, human-authored writing data used by Flow regression tests and the
/// numbered real-app QA document. Correct source text and mutation goldens are
/// authored; SplitMix64 deterministically groups and applies their edit
/// manifests and selects the stratified QA sample. It never authors prose.
enum FlowWritingCorpus {
    static let seed: UInt64 = 0x4D4F_4E4B_4E4F_5421

    static let repairCases: [FlowWritingRepairCase] = {
        var generator = FlowWritingSplitMix64(seed: seed)
        return seededShuffle(repairDrafts, using: &generator)
    }()

    static let autocompleteCases: [FlowWritingAutocompleteCase] = {
        var generator = FlowWritingSplitMix64(seed: seed &+ UInt64(repairDrafts.count))
        return seededShuffle(autocompleteDrafts, using: &generator)
    }()

    /// Selected before runtime from four fixed strata. The seed currently
    /// chooses stride one; changing the seed changes the deterministic walk,
    /// while the corpus test separately golden-freezes the resulting IDs.
    static let qaSampleIDs: [String] = {
        func select(
            _ candidates: [FlowWritingRepairCase],
            count: Int
        ) -> [String] {
            let sorted = candidates.sorted { left, right in
                let leftRank = left.expectation == .exactDeterministic ? 0 : 1
                let rightRank = right.expectation == .exactDeterministic ? 0 : 1
                return leftRank == rightRank ? left.id < right.id : leftRank < rightRank
            }
            precondition(sorted.count >= count)
            var generator = FlowWritingSplitMix64(seed: seed)
            let stride = Int(generator.next() % 3) + 1
            let offset = Int(generator.next() % UInt64(stride))
            var selected: [String] = []
            var index = offset
            while selected.count < count {
                let id = sorted[index % sorted.count].id
                if !selected.contains(id) { selected.append(id) }
                index += stride
            }
            return selected
        }

        let simple = repairCases.filter {
            $0.expectation == .exactDeterministic
                && !$0.isMultiError
                && !$0.isLongOrHardWrapped
        }
        let multi = repairCases.filter {
            $0.expectation == .exactDeterministic
                && $0.isMultiError
                && !$0.isLongOrHardWrapped
        }
        let long = repairCases.filter {
            $0.isLongOrHardWrapped && $0.expectation != .protectedUnsafe
        }
        let protected = repairCases.filter { $0.expectation == .protectedUnsafe }
        return select(simple, count: 5)
            + select(multi, count: 5)
            + select(long, count: 5)
            + select(protected, count: 5)
    }()

    static var qaMarkdown: String {
        let casesByID = Dictionary(uniqueKeysWithValues: repairCases.map { ($0.id, $0) })
        var lines = [
            "# Monknot Flow Fixed-Corpus QA",
            "",
            "Seed: `0x4D4F4E4B4E4F5421`",
            "",
            "These case numbers and IDs were frozen before product execution. Run 10 assigned cases by typing and 10 by paste. Enter final punctuation or Return as a separate event.",
            "",
        ]
        for (index, id) in qaSampleIDs.enumerated() {
            guard let testCase = casesByID[id] else { continue }
            lines.append("## Case \(String(format: "%02d", index + 1)) — `\(testCase.id)`")
            lines.append("")
            lines.append("- Domain: \(testCase.domain.rawValue)")
            lines.append("- Classification: \(testCase.expectation.qaLabel)")
            lines.append("- Trigger: \(testCase.trigger.qaLabel)")
            lines.append("- Mutations: \(testCase.mutations.map(\.rawValue).joined(separator: ", "))")
            lines.append("- Long or hard-wrapped: \(testCase.isLongOrHardWrapped ? "yes" : "no")")
            lines.append("- Input:")
            lines.append("")
            lines.append("~~~text")
            lines.append(testCase.input)
            lines.append("~~~")
            lines.append("")
            lines.append("- Human reference (not a required exact AI wording):")
            lines.append("")
            lines.append("~~~text")
            lines.append(testCase.referenceText)
            lines.append("~~~")
            lines.append("")
            lines.append("- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func seededShuffle<Element>(
        _ source: [Element],
        using generator: inout FlowWritingSplitMix64
    ) -> [Element] {
        guard source.count > 1 else { return source }
        var result = source
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            let selected = Int(generator.next() % UInt64(index + 1))
            result.swapAt(index, selected)
        }
        return result
    }

    static func applyMutationManifest(
        _ manifest: [FlowWritingMutationOperation],
        to source: String
    ) -> String {
        let result = NSMutableString(string: source)
        var applied: [(range: NSRange, delta: Int)] = []
        for operation in manifest {
            let precedingDelta = applied.reduce(into: 0) { total, prior in
                if prior.range.location < operation.range.location {
                    total += prior.delta
                }
            }
            let adjusted = NSRange(
                location: operation.range.location + precedingDelta,
                length: operation.range.length
            )
            precondition(adjusted.location >= 0 && NSMaxRange(adjusted) <= result.length)
            result.replaceCharacters(in: adjusted, with: operation.replacementText)
            applied.append((
                range: operation.range,
                delta: (operation.replacementText as NSString).length - operation.range.length
            ))
        }
        return result as String
    }

    private static func mutationManifest(
        source: String,
        frozenExpectedInput: String,
        id: String
    ) -> [FlowWritingMutationOperation] {
        guard source != frozenExpectedInput else { return [] }
        let sourceCharacters = Array(source)
        let expectedCharacters = Array(frozenExpectedInput)
        let difference = expectedCharacters.difference(from: sourceCharacters)
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
        let sourceMatches = sourceCharacters.indices.filter { !removedOffsets.contains($0) }
        let expectedMatches = expectedCharacters.indices.filter { !insertedOffsets.contains($0) }
        precondition(sourceMatches.count == expectedMatches.count)
        precondition(zip(sourceMatches, expectedMatches).allSatisfy {
            sourceCharacters[$0] == expectedCharacters[$1]
        })

        func utf16Offsets(_ characters: [Character]) -> [Int] {
            var offsets = [0]
            offsets.reserveCapacity(characters.count + 1)
            for character in characters {
                offsets.append(offsets.last! + String(character).utf16.count)
            }
            return offsets
        }
        let sourceOffsets = utf16Offsets(sourceCharacters)
        let expectedOffsets = utf16Offsets(expectedCharacters)
        let expectedNSString = frozenExpectedInput as NSString
        let matches = Array(zip(sourceMatches, expectedMatches))
            + [(sourceCharacters.count, expectedCharacters.count)]
        var previousSource = -1
        var previousExpected = -1
        var manifest: [FlowWritingMutationOperation] = []
        for (currentSource, currentExpected) in matches {
            let sourceStart = previousSource + 1
            let expectedStart = previousExpected + 1
            if sourceStart < currentSource || expectedStart < currentExpected {
                let sourceRange = NSRange(
                    location: sourceOffsets[sourceStart],
                    length: sourceOffsets[currentSource] - sourceOffsets[sourceStart]
                )
                let expectedRange = NSRange(
                    location: expectedOffsets[expectedStart],
                    length: expectedOffsets[currentExpected] - expectedOffsets[expectedStart]
                )
                manifest.append(FlowWritingMutationOperation(
                    range: sourceRange,
                    replacementText: expectedNSString.substring(with: expectedRange)
                ))
            }
            previousSource = currentSource
            previousExpected = currentExpected
        }

        // The fixed seed determines the operation schedule. Ranges retain
        // authoritative-source coordinates; materialization rebases each
        // scheduled operation over earlier edits.
        var generator = FlowWritingSplitMix64(seed: seed ^ stableIDHash(id))
        return seededShuffle(manifest, using: &generator)
    }

    private static func stableIDHash(_ id: String) -> UInt64 {
        id.utf8.reduce(0xCBF2_9CE4_8422_2325) { value, byte in
            (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
    }
}

struct FlowWritingSplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

enum FlowWritingDomain: String, CaseIterable {
    case personalMessage = "personal message"
    case workUpdate = "work update"
    case email
    case meetingNote = "meeting note"
    case healthMessage = "health-related message"
    case projectSummary = "project summary"
    case planningNote = "planning note"
    case longForm = "longer paragraph"
    case hardWrappedProse = "hard-wrapped prose"
}

enum FlowWritingMutationKind: String, CaseIterable {
    case spelling = "spelling mistake"
    case adjacentTransposition = "adjacent-letter transposition"
    case missingShortWord = "missing short word"
    case duplicatedWord = "duplicated word"
    case subjectVerbAgreement = "subject–verb disagreement"
    case wrongArticle = "wrong article"
    case wrongPreposition = "wrong preposition"
    case localReorder = "local word reorder"
    case missingComma = "missing comma"
    case incorrectPunctuation = "incorrect punctuation"
    case capitalization = "capitalization error"
    case runOnClause = "run-on clause"
}

enum FlowWritingRepairExpectation: String, CaseIterable {
    case exactDeterministic
    case aiInvariant
    case protectedUnsafe
    case clean

    var qaLabel: String {
        switch self {
        case .exactDeterministic:
            return "exact deterministic"
        case .aiInvariant:
            return "AI invariant"
        case .protectedUnsafe:
            return "protected / unsafe"
        case .clean:
            return "clean"
        }
    }
}

enum FlowWritingTrigger: Equatable {
    case punctuation(Character, trailingDelimiterCount: Int = 0)
    case returnKey

    var qaLabel: String {
        switch self {
        case let .punctuation(character, trailingDelimiterCount):
            let suffix = trailingDelimiterCount == 0
                ? ""
                : " followed by \(trailingDelimiterCount) closing delimiter(s)"
            return "punctuation `\(character)`\(suffix)"
        case .returnKey:
            return "Return"
        }
    }
}

struct FlowWritingRepairCase: Equatable {
    let id: String
    let domain: FlowWritingDomain
    let mutationManifest: [FlowWritingMutationOperation]
    let input: String
    let referenceText: String
    let expectation: FlowWritingRepairExpectation
    let conservativeCandidateFixture: String?
    let mutations: [FlowWritingMutationKind]
    let trigger: FlowWritingTrigger
    let isLongOrHardWrapped: Bool
    let preservedAnchors: [String]
    let protectedFragments: [String]

    var isMultiError: Bool {
        mutations.count >= 2
    }

    var expectedFinalText: String {
        switch expectation {
        case .exactDeterministic:
            return referenceText
        case .aiInvariant:
            return conservativeCandidateFixture ?? referenceText
        case .protectedUnsafe, .clean:
            return input
        }
    }

    var wordCount: Int {
        var count = 0
        input.enumerateSubstrings(
            in: input.startIndex..<input.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }
}

struct FlowWritingMutationOperation: Equatable {
    /// UTF-16 range in the authoritative correct source.
    let range: NSRange
    let replacementText: String
}

enum FlowWritingAutocompleteExpectation: String, CaseIterable {
    case useful
    case restatementOrGeneric
    case unsafe
}

struct FlowWritingAutocompleteCase: Equatable {
    let id: String
    let domain: FlowWritingDomain
    let context: String
    let modelOutput: String
    let expectedContinuation: String?
    let expectation: FlowWritingAutocompleteExpectation
}

private extension FlowWritingCorpus {
    static func repair(
        _ id: String,
        _ domain: FlowWritingDomain,
        input: String,
        reference: String,
        expectation: FlowWritingRepairExpectation,
        conservativeCandidateFixture: String? = nil,
        mutations: [FlowWritingMutationKind],
        trigger: FlowWritingTrigger = .punctuation("."),
        long: Bool = false,
        anchors: [String] = [],
        protected: [String] = []
    ) -> FlowWritingRepairCase {
        let manifest = mutationManifest(
            source: reference,
            frozenExpectedInput: input,
            id: id
        )
        let generatedInput = applyMutationManifest(manifest, to: reference)
        precondition(generatedInput == input, "Mutation golden drift for \(id)")
        return FlowWritingRepairCase(
            id: id,
            domain: domain,
            mutationManifest: manifest,
            input: generatedInput,
            referenceText: reference,
            expectation: expectation,
            conservativeCandidateFixture: conservativeCandidateFixture,
            mutations: mutations,
            trigger: trigger,
            isLongOrHardWrapped: long,
            preservedAnchors: anchors,
            protectedFragments: protected
        )
    }

    static let repairDrafts: [FlowWritingRepairCase] = exactRepairDrafts
        + aiRepairDrafts
        + protectedRepairDrafts
        + cleanRepairDrafts

    static let exactRepairDrafts: [FlowWritingRepairCase] = [
        repair(
            "repair-exact-001", .personalMessage,
            input: "I will brnig the keys when I meet you outside.",
            reference: "I will bring the keys when I meet you outside.",
            expectation: .exactDeterministic,
            mutations: [.adjacentTransposition]
        ),
        repair(
            "repair-exact-002", .workUpdate,
            input: "The release notes is ready for review by the support team.",
            reference: "The release notes are ready for review by the support team.",
            expectation: .exactDeterministic,
            mutations: [.subjectVerbAgreement]
        ),
        repair(
            "repair-exact-003", .email,
            input: "I attached a updated estimate for the client meeting.",
            reference: "I attached an updated estimate for the client meeting.",
            expectation: .exactDeterministic,
            mutations: [.wrongArticle]
        ),
        repair(
            "repair-exact-004", .meetingNote,
            input: "After the demo we will collect questions from the design team.",
            reference: "After the demo, we will collect questions from the design team.",
            expectation: .exactDeterministic,
            mutations: [.missingComma]
        ),
        repair(
            "repair-exact-005", .healthMessage,
            input: "I need to rescheduel my appointment because I have a fever.",
            reference: "I need to reschedule my appointment because I have a fever.",
            expectation: .exactDeterministic,
            mutations: [.spelling]
        ),
        repair(
            "repair-exact-006", .projectSummary,
            input: "the export now preserves every heading during PDF generation.",
            reference: "The export now preserves every heading during PDF generation.",
            expectation: .exactDeterministic,
            mutations: [.capitalization],
            anchors: ["PDF"]
        ),
        repair(
            "repair-exact-007", .planningNote,
            input: "We will meet in Friday to confirm the launch checklist.",
            reference: "We will meet on Friday to confirm the launch checklist.",
            expectation: .exactDeterministic,
            mutations: [.wrongPreposition],
            anchors: ["Friday"]
        ),
        repair(
            "repair-exact-008", .personalMessage,
            input: "Could you call me when you arrive!",
            reference: "Could you call me when you arrive?",
            expectation: .exactDeterministic,
            mutations: [.incorrectPunctuation],
            trigger: .punctuation("!")
        ),
        repair(
            "repair-exact-009", .email,
            input: "Mira wrote, “Please snd the revised invoice today.”",
            reference: "Mira wrote, “Please send the revised invoice today.”",
            expectation: .exactDeterministic,
            mutations: [.spelling],
            trigger: .punctuation(".", trailingDelimiterCount: 1),
            anchors: ["Mira"]
        ),
        repair(
            "repair-exact-010", .meetingNote,
            input: "The agenda lists the final desicion [approve the budget].",
            reference: "The agenda lists the final decision [approve the budget].",
            expectation: .exactDeterministic,
            mutations: [.spelling],
            anchors: ["[approve the budget]"]
        ),
        repair(
            "repair-exact-011", .workUpdate,
            input: "Maya will publsih the report on August 18, 2026.",
            reference: "Maya will publish the report on August 18, 2026.",
            expectation: .exactDeterministic,
            mutations: [.adjacentTransposition],
            anchors: ["Maya", "August 18, 2026"]
        ),
        repair(
            "repair-exact-012", .projectSummary,
            input: "Version 3.2 contians two migration fixes and one rollback note.",
            reference: "Version 3.2 contains two migration fixes and one rollback note.",
            expectation: .exactDeterministic,
            mutations: [.adjacentTransposition],
            anchors: ["Version 3.2", "two", "one"]
        ),
        repair(
            "repair-exact-013", .workUpdate,
            input: "The enginers is testing the backup process before tonight.",
            reference: "The engineers are testing the backup process before tonight.",
            expectation: .exactDeterministic,
            mutations: [.spelling, .subjectVerbAgreement]
        ),
        repair(
            "repair-exact-014", .meetingNote,
            input: "We scheduled an review in Monday for the new prototype.",
            reference: "We scheduled a review on Monday for the new prototype.",
            expectation: .exactDeterministic,
            mutations: [.wrongArticle, .wrongPreposition],
            anchors: ["Monday"]
        ),
        repair(
            "repair-exact-015", .email,
            input: "after lunch Priya will chekc the figures and send the summary.",
            reference: "After lunch, Priya will check the figures and send the summary.",
            expectation: .exactDeterministic,
            mutations: [.capitalization, .missingComma, .adjacentTransposition],
            anchors: ["Priya"]
        ),
        repair(
            "repair-exact-016", .personalMessage,
            input: "Can you confrim the adress before we leave.",
            reference: "Can you confirm the address before we leave?",
            expectation: .exactDeterministic,
            mutations: [.spelling, .spelling, .incorrectPunctuation]
        ),
        repair(
            "repair-exact-017", .meetingNote,
            input: "The meeting notes was uploded to the shared folder.",
            reference: "The meeting notes were uploaded to the shared folder.",
            expectation: .exactDeterministic,
            mutations: [.subjectVerbAgreement, .spelling]
        ),
        repair(
            "repair-exact-018", .healthMessage,
            input: "I need an seperate room for the video call.",
            reference: "I need a separate room for the video call.",
            expectation: .exactDeterministic,
            mutations: [.wrongArticle, .spelling]
        ),
        repair(
            "repair-exact-019", .planningNote,
            input: "Before Friday we should agree at the final scope.",
            reference: "Before Friday, we should agree on the final scope.",
            expectation: .exactDeterministic,
            mutations: [.missingComma, .wrongPreposition],
            anchors: ["Friday"]
        ),
        repair(
            "repair-exact-020", .workUpdate,
            input: "our two vendors has submitted complete security questionnaires.",
            reference: "Our two vendors have submitted complete security questionnaires.",
            expectation: .exactDeterministic,
            mutations: [.capitalization, .subjectVerbAgreement],
            anchors: ["two"]
        ),
        repair(
            "repair-exact-021", .hardWrappedProse,
            input: "The tehcnical review found no critical risks during the first pass,\nbut the second revieiw found a critcal deployment warning.",
            reference: "The technical review found no critical risks during the first pass,\nbut the second review found a critical deployment warning.",
            expectation: .exactDeterministic,
            mutations: [.adjacentTransposition, .spelling, .spelling],
            long: true
        ),
        repair(
            "repair-exact-022", .hardWrappedProse,
            input: "In the final note, Sofia asked,\n“Is the packages ready for the Berlin office.\u{201d}",
            reference: "In the final note, Sofia asked,\n“Are the packages ready for the Berlin office?\u{201d}",
            expectation: .exactDeterministic,
            mutations: [.subjectVerbAgreement, .incorrectPunctuation],
            trigger: .punctuation(".", trailingDelimiterCount: 1),
            long: true,
            anchors: ["Sofia", "Berlin"]
        ),
        repair(
            "repair-exact-023", .hardWrappedProse,
            input: "The release checklist [verfy backups and notifiy owners] is ready for the rehearsal,\nand Project Cedar have no other blocking issue.",
            reference: "The release checklist [verify backups and notify owners] is ready for the rehearsal,\nand Project Cedar has no other blocking issue.",
            expectation: .exactDeterministic,
            mutations: [.spelling, .spelling, .subjectVerbAgreement],
            long: true,
            anchors: ["Project Cedar"]
        ),
        repair(
            "repair-exact-024", .longForm,
            input: "After the first rehearsal the release managers cheked every backup, the support leads confirms the escalation list, and the documentation team publshed the recovery steps so each owner could review the plan before the scheduled maintenance window on September 4, 2026.",
            reference: "After the first rehearsal, the release managers checked every backup, the support leads confirmed the escalation list, and the documentation team published the recovery steps so each owner could review the plan before the scheduled maintenance window on September 4, 2026.",
            expectation: .exactDeterministic,
            mutations: [.missingComma, .spelling, .subjectVerbAgreement, .spelling],
            long: true,
            anchors: ["September 4, 2026"]
        ),
    ]
}

private extension FlowWritingCorpus {
    static let aiRepairDrafts: [FlowWritingRepairCase] = [
        repair(
            "repair-ai-001", .healthMessage,
            input: "My ankle did nt improve overnight after the new exercises the swelling look worse and the clinic have not replyed yet.",
            reference: "My ankle did not improve overnight after the new exercises; the swelling looks worse, and the clinic has not replied yet.",
            expectation: .aiInvariant,
            conservativeCandidateFixture: "My ankle did not improve overnight after the new exercises; the swelling looks worse, and the clinic has not replied yet.",
            mutations: [.spelling, .subjectVerbAgreement, .runOnClause, .subjectVerbAgreement, .spelling],
            long: true
        ),
        repair(
            "repair-ai-002", .personalMessage,
            input: "I wanted let you know that the train is delayed.",
            reference: "I wanted to let you know that the train is delayed.",
            expectation: .aiInvariant,
            mutations: [.missingShortWord]
        ),
        repair(
            "repair-ai-003", .email,
            input: "We need send draft to team before noon.",
            reference: "We need to send the draft to the team before noon.",
            expectation: .aiInvariant,
            mutations: [.missingShortWord, .missingShortWord]
        ),
        repair(
            "repair-ai-004", .personalMessage,
            input: "The lanterns is flickring beside the footpath.",
            reference: "The lanterns are flickering beside the footpath.",
            expectation: .aiInvariant,
            mutations: [.subjectVerbAgreement, .spelling]
        ),
        repair(
            "repair-ai-005", .workUpdate,
            input: "After review an engineer will send a update.",
            reference: "After review, an engineer will send an update.",
            expectation: .aiInvariant,
            mutations: [.missingComma, .wrongArticle]
        ),
        repair(
            "repair-ai-006", .meetingNote,
            input: "The team team approved the revised agenda before lunch.",
            reference: "The team approved the revised agenda before lunch.",
            expectation: .aiInvariant,
            mutations: [.duplicatedWord]
        ),
        repair(
            "repair-ai-007", .workUpdate,
            input: "I finished yesterday the client summary and shared it with Omar.",
            reference: "I finished the client summary yesterday and shared it with Omar.",
            expectation: .aiInvariant,
            mutations: [.localReorder],
            anchors: ["Omar"]
        ),
        repair(
            "repair-ai-008", .planningNote,
            input: "We reviewed the launch plan it still needs a rollback owner.",
            reference: "We reviewed the launch plan, but it still needs a rollback owner.",
            expectation: .aiInvariant,
            conservativeCandidateFixture: "We reviewed the launch plan; it still needs a rollback owner.",
            mutations: [.runOnClause, .missingShortWord]
        ),
        repair(
            "repair-ai-009", .longForm,
            input: "Before the workshop begins we should test the projector confirm the guest list print the revised schedule and ask each speaker whether they need a adapter or an additional microphone.",
            reference: "Before the workshop begins, we should test the projector, confirm the guest list, print the revised schedule, and ask each speaker whether they need an adapter or an additional microphone.",
            expectation: .aiInvariant,
            mutations: [.missingComma, .missingComma, .missingComma, .wrongArticle],
            long: true
        ),
        repair(
            "repair-ai-010", .healthMessage,
            input: "I started feeling dizzy last night I slept badly and this morning I cant safely drive to the clinic for my appointment.",
            reference: "I started feeling dizzy last night, slept badly, and cannot safely drive to the clinic for my appointment this morning.",
            expectation: .aiInvariant,
            conservativeCandidateFixture: "I started feeling dizzy last night, I slept badly, and this morning I cannot safely drive to the clinic for my appointment.",
            mutations: [.runOnClause, .incorrectPunctuation, .spelling],
            long: true,
            anchors: ["clinic", "appointment"]
        ),
        repair(
            "repair-ai-011", .meetingNote,
            input: "The notes says design will send prototype support review it tomorrow.",
            reference: "The notes say that design will send the prototype, and support will review it tomorrow.",
            expectation: .aiInvariant,
            conservativeCandidateFixture: "The notes say that design will send the prototype, and support reviews it tomorrow.",
            mutations: [.subjectVerbAgreement, .missingShortWord, .missingShortWord, .missingComma]
        ),
        repair(
            "repair-ai-012", .workUpdate,
            input: "The archive archive are ready but three labels still needs review.",
            reference: "The archive is ready, but three labels still need review.",
            expectation: .aiInvariant,
            mutations: [.duplicatedWord, .subjectVerbAgreement, .missingComma, .subjectVerbAgreement],
            anchors: ["three"]
        ),
        repair(
            "repair-ai-013", .email,
            input: "Hello Daniel I am writng because invoice 4821 have not arrived can you send it again.",
            reference: "Hello Daniel, I am writing because invoice 4821 has not arrived; can you send it again?",
            expectation: .aiInvariant,
            mutations: [.missingComma, .spelling, .subjectVerbAgreement, .incorrectPunctuation],
            anchors: ["Daniel", "4821"]
        ),
        repair(
            "repair-ai-014", .hardWrappedProse,
            input: "The import now keeps headings and code spans but it still loose link titles\nwhen a document are moved and the destination contains a space.",
            reference: "The import now keeps headings and code spans, but it still loses link titles\nwhen a document is moved and the destination contains a space.",
            expectation: .aiInvariant,
            mutations: [.missingComma, .spelling, .subjectVerbAgreement],
            trigger: .returnKey,
            long: true,
            anchors: ["headings", "code spans", "link titles"]
        ),
        repair(
            "repair-ai-015", .longForm,
            input: "On Friday Maya will compare the two vendor proposals the security notes from March and every open question then she send a recommendation to Project Cedar owners before the budget meeting starts.",
            reference: "On Friday, Maya will compare the two vendor proposals, the security notes from March, and every open question; then she will send a recommendation to the Project Cedar owners before the budget meeting starts.",
            expectation: .aiInvariant,
            conservativeCandidateFixture: "On Friday, Maya will compare the two vendor proposals, the security notes from March, and every open question; then she sends a recommendation to the Project Cedar owners before the budget meeting starts.",
            mutations: [.missingComma, .missingComma, .subjectVerbAgreement, .missingShortWord],
            long: true,
            anchors: ["Friday", "Maya", "two", "March", "Project Cedar"]
        ),
        repair(
            "repair-ai-016", .personalMessage,
            input: "Lea said, “I cant join tonight the babysitter cancel and I need stay home.”",
            reference: "Lea said, “I cannot join tonight because the babysitter cancelled, and I need to stay home.”",
            expectation: .aiInvariant,
            conservativeCandidateFixture: "Lea said, “I cannot join tonight; the babysitter cancelled, and I need to stay home.”",
            mutations: [.spelling, .missingShortWord, .spelling, .missingComma, .missingShortWord],
            trigger: .punctuation(".", trailingDelimiterCount: 1),
            anchors: ["Lea", "tonight"]
        ),
        repair(
            "repair-ai-017", .workUpdate,
            input: "Nora finish the Vienna audit on August 21, 2026 and the three findings was shared unchanged.",
            reference: "Nora finished the Vienna audit on August 21, 2026, and the three findings were shared unchanged.",
            expectation: .aiInvariant,
            mutations: [.subjectVerbAgreement, .missingComma, .subjectVerbAgreement],
            anchors: ["Nora", "Vienna", "August 21, 2026", "three"]
        ),
        repair(
            "repair-ai-018", .projectSummary,
            input: "Build MK-204 contain 17 fixes it do not change the saved workspace format.",
            reference: "Build MK-204 contains 17 fixes; it does not change the saved workspace format.",
            expectation: .aiInvariant,
            mutations: [.subjectVerbAgreement, .runOnClause, .subjectVerbAgreement],
            anchors: ["MK-204", "17"]
        ),
        repair(
            "repair-ai-019", .projectSummary,
            input: "The note marks **Launch Ready** but it do not explains why the PDF export fail.",
            reference: "The note marks **Launch Ready**, but it does not explain why the PDF export fails.",
            expectation: .aiInvariant,
            mutations: [.missingComma, .subjectVerbAgreement, .subjectVerbAgreement, .subjectVerbAgreement],
            anchors: ["**Launch Ready**", "PDF"]
        ),
        repair(
            "repair-ai-020", .longForm,
            input: "Before the autumn launch the research team interview twelve customers from Vienna Berlin and Prague then compare those notes with support tickets collected since March the team also need test imports on two older Macs verify every Markdown link and ask Maya to record unresolved risks for Project Cedar before August 28, 2026.",
            reference: "Before the autumn launch, the research team will interview twelve customers from Vienna, Berlin, and Prague, then compare those notes with support tickets collected since March; the team also needs to test imports on two older Macs, verify every Markdown link, and ask Maya to record unresolved risks for Project Cedar before August 28, 2026.",
            expectation: .aiInvariant,
            conservativeCandidateFixture: "Before the autumn launch, the research team interviews twelve customers from Vienna, Berlin, and Prague, then compares those notes with support tickets collected since March; the team also needs to test imports on two older Macs, verify every Markdown link, and ask Maya to record unresolved risks for Project Cedar before August 28, 2026.",
            mutations: [.missingComma, .subjectVerbAgreement, .runOnClause, .subjectVerbAgreement, .missingShortWord],
            long: true,
            anchors: ["twelve", "Vienna", "Berlin", "Prague", "March", "two", "Markdown", "Maya", "Project Cedar", "August 28, 2026"]
        ),
    ]

    static let protectedRepairDrafts: [FlowWritingRepairCase] = [
        repair(
            "repair-protected-001", .projectSummary,
            input: "Use `tehFlag` in the example before running the command.",
            reference: "Use `theFlag` in the example before running the command.",
            expectation: .protectedUnsafe,
            mutations: [.spelling],
            protected: ["`tehFlag`"]
        ),
        repair(
            "repair-protected-002", .projectSummary,
            input: "Keep this sample unchanged:\n```swift\nfunc load() { retrun value }\n```\nThen continue with the explanation.",
            reference: "Keep this sample unchanged:\n```swift\nfunc load() { return value }\n```\nThen continue with the explanation.",
            expectation: .protectedUnsafe,
            mutations: [.spelling],
            trigger: .returnKey,
            protected: ["```swift\nfunc load() { retrun value }\n```"]
        ),
        repair(
            "repair-protected-003", .email,
            input: "Open the reference at [the guide](https://example.com/teh-guide) after the meeting.",
            reference: "Open the reference at [the guide](https://example.com/the-guide) after the meeting.",
            expectation: .protectedUnsafe,
            mutations: [.spelling],
            protected: ["https://example.com/teh-guide"]
        ),
        repair(
            "repair-protected-004", .planningNote,
            input: "Visit https://teh.example.com/releases before updating the launch checklist.",
            reference: "Visit https://the.example.com/releases before updating the launch checklist.",
            expectation: .protectedUnsafe,
            mutations: [.spelling],
            protected: ["https://teh.example.com/releases"]
        ),
        repair(
            "repair-protected-005", .personalMessage,
            input: "Send the receipt to teh.user@example.com after lunch today.",
            reference: "Send the receipt to the.user@example.com after lunch today.",
            expectation: .protectedUnsafe,
            mutations: [.spelling],
            protected: ["teh.user@example.com"]
        ),
        repair(
            "repair-protected-006", .projectSummary,
            input: "---\ntitle: teh migration plan\ndate: 2026-08-18\n---\nReview the metadata before publishing this document.",
            reference: "---\ntitle: the migration plan\ndate: 2026-08-18\n---\nReview the metadata before publishing this document.",
            expectation: .protectedUnsafe,
            mutations: [.spelling],
            trigger: .returnKey,
            anchors: ["2026-08-18"],
            protected: ["title: teh migration plan", "date: 2026-08-18"]
        ),
        repair(
            "repair-protected-007", .projectSummary,
            input: "Keep ![Chart](assets/teh-chart.png) beside the quarterly summary.",
            reference: "Keep ![Chart](assets/the-chart.png) beside the quarterly summary.",
            expectation: .protectedUnsafe,
            mutations: [.spelling],
            protected: ["assets/teh-chart.png"]
        ),
        repair(
            "repair-protected-008", .planningNote,
            input: "Link this note to [[teh-roadmap]] before closing the planning session.",
            reference: "Link this note to [[the-roadmap]] before closing the planning session.",
            expectation: .protectedUnsafe,
            mutations: [.spelling],
            protected: ["[[teh-roadmap]]"]
        ),
        repair(
            "repair-protected-009", .hardWrappedProse,
            input: "The example keeps its data attribute across the wrapped paragraph,\nso leave <span data-note=\"teh value\">this label</span> exactly as written during every repair.",
            reference: "The example keeps its data attribute across the wrapped paragraph,\nso leave <span data-note=\"the value\">this label</span> exactly as written during every repair.",
            expectation: .protectedUnsafe,
            mutations: [.spelling],
            trigger: .returnKey,
            long: true,
            protected: ["<span data-note=\"teh value\">this label</span>"]
        ),
        repair(
            "repair-protected-010", .email,
            input: "Share <https://example.com/teh-path> with the support group after the call.",
            reference: "Share <https://example.com/the-path> with the support group after the call.",
            expectation: .protectedUnsafe,
            mutations: [.spelling],
            protected: ["<https://example.com/teh-path>"]
        ),
    ]

    static let cleanRepairDrafts: [FlowWritingRepairCase] = [
        repair(
            "repair-clean-001", .personalMessage,
            input: "I will call after lunch.",
            reference: "I will call after lunch.",
            expectation: .clean,
            mutations: []
        ),
        repair(
            "repair-clean-002", .workUpdate,
            input: "The release notes are ready for the support team.",
            reference: "The release notes are ready for the support team.",
            expectation: .clean,
            mutations: []
        ),
        repair(
            "repair-clean-003", .email,
            input: "Hello Ana, I attached the signed agreement for your records.",
            reference: "Hello Ana, I attached the signed agreement for your records.",
            expectation: .clean,
            mutations: [],
            anchors: ["Ana"]
        ),
        repair(
            "repair-clean-004", .meetingNote,
            input: "The group approved the agenda and scheduled the next review.",
            reference: "The group approved the agenda and scheduled the next review.",
            expectation: .clean,
            mutations: []
        ),
        repair(
            "repair-clean-005", .healthMessage,
            input: "I feel better today and can attend the afternoon appointment.",
            reference: "I feel better today and can attend the afternoon appointment.",
            expectation: .clean,
            mutations: []
        ),
        repair(
            "repair-clean-006", .longForm,
            input: "Before the autumn launch, the research team will interview twelve customers from Vienna, Berlin, and Prague, compare their notes with the support tickets collected since March, review the accessibility findings with Maya and Omar, test the new import workflow on small and large workspaces, verify that every Markdown link still opens the intended document, confirm that PDF exports preserve headings and page breaks, measure startup time on two older Macs, document every unresolved risk in Project Cedar, ask the legal team to review the updated privacy language, schedule a final rehearsal for August 28, 2026, share the release checklist with engineering, design, support, and marketing, collect written approval from each owner, prepare a rollback plan that does not remove local drafts, publish the maintenance window in advance, and leave enough time for one final build if the rehearsal reveals a serious issue before customers receive the update on launch day.",
            reference: "Before the autumn launch, the research team will interview twelve customers from Vienna, Berlin, and Prague, compare their notes with the support tickets collected since March, review the accessibility findings with Maya and Omar, test the new import workflow on small and large workspaces, verify that every Markdown link still opens the intended document, confirm that PDF exports preserve headings and page breaks, measure startup time on two older Macs, document every unresolved risk in Project Cedar, ask the legal team to review the updated privacy language, schedule a final rehearsal for August 28, 2026, share the release checklist with engineering, design, support, and marketing, collect written approval from each owner, prepare a rollback plan that does not remove local drafts, publish the maintenance window in advance, and leave enough time for one final build if the rehearsal reveals a serious issue before customers receive the update on launch day.",
            expectation: .clean,
            mutations: [],
            long: true,
            anchors: ["twelve", "Vienna", "Berlin", "Prague", "March", "Maya", "Omar", "Markdown", "PDF", "two", "Project Cedar", "August 28, 2026"]
        ),
    ]
}

private extension FlowWritingCorpus {
    static func autocomplete(
        _ id: String,
        _ domain: FlowWritingDomain,
        context: String,
        output: String,
        expected: String?,
        expectation: FlowWritingAutocompleteExpectation
    ) -> FlowWritingAutocompleteCase {
        FlowWritingAutocompleteCase(
            id: id,
            domain: domain,
            context: context,
            modelOutput: output,
            expectedContinuation: expected,
            expectation: expectation
        )
    }

    static let autocompleteDrafts: [FlowWritingAutocompleteCase] = [
        autocomplete(
            "autocomplete-useful-001", .personalMessage,
            context: "I can meet after lunch",
            output: "if the train arrives on time.",
            expected: " if the train arrives on time.",
            expectation: .useful
        ),
        autocomplete(
            "autocomplete-useful-002", .workUpdate,
            context: "The migration is complete",
            output: "and the final checks start tomorrow.",
            expected: " and the final checks start tomorrow.",
            expectation: .useful
        ),
        autocomplete(
            "autocomplete-useful-003", .email,
            context: "Please review the attached estimate",
            output: "before our call on Friday.",
            expected: " before our call on Friday.",
            expectation: .useful
        ),
        autocomplete(
            "autocomplete-useful-004", .meetingNote,
            context: "The team approved the agenda",
            output: "but deferred the budget decision.",
            expected: " but deferred the budget decision.",
            expectation: .useful
        ),
        autocomplete(
            "autocomplete-useful-005", .healthMessage,
            context: "I feel better this morning",
            output: "and can attend the appointment.",
            expected: " and can attend the appointment.",
            expectation: .useful
        ),
        autocomplete(
            "autocomplete-useful-006", .projectSummary,
            context: "The export preserves every heading",
            output: "while keeping page breaks stable.",
            expected: " while keeping page breaks stable.",
            expectation: .useful
        ),
        autocomplete(
            "autocomplete-useful-007", .planningNote,
            context: "We should compare both proposals",
            output: "before selecting a vendor.",
            expected: " before selecting a vendor.",
            expectation: .useful
        ),
        autocomplete(
            "autocomplete-useful-008", .hardWrappedProse,
            context: "The first paragraph explains the risk\nand the next sentence",
            output: "describes the safest fallback.",
            expected: " describes the safest fallback.",
            expectation: .useful
        ),
        autocomplete(
            "autocomplete-restatement-001", .email,
            context: "Hello im wiritng this to exprs that",
            output: "Hello, I’m writing this to express that I’m…",
            expected: nil,
            expectation: .restatementOrGeneric
        ),
        autocomplete(
            "autocomplete-restatement-002", .planningNote,
            context: "We typed teh",
            output: "the next step",
            expected: nil,
            expectation: .restatementOrGeneric
        ),
        autocomplete(
            "autocomplete-restatement-003", .meetingNote,
            context: "We agreed adn",
            output: "and continue",
            expected: nil,
            expectation: .restatementOrGeneric
        ),
        autocomplete(
            "autocomplete-restatement-004", .email,
            context: "I am writng",
            output: "so writing clearly will help.",
            expected: nil,
            expectation: .restatementOrGeneric
        ),
        autocomplete(
            "autocomplete-restatement-005", .workUpdate,
            context: "Our note says teh launch is Friday",
            output: "and the launch is Friday for everyone.",
            expected: nil,
            expectation: .restatementOrGeneric
        ),
        autocomplete(
            "autocomplete-restatement-006", .longForm,
            context: "Public parks matter because they give crowded neighborhoods room to gather and rest",
            output: "Public parks matter for healthy neighborhoods.",
            expected: " Public parks matter for healthy neighborhoods.",
            expectation: .useful
        ),
        autocomplete(
            "autocomplete-restatement-007", .projectSummary,
            context: "A focused draft helps readers decide. We will compare the options tomorrow",
            output: "A focused draft helps readers decide before lunch.",
            expected: nil,
            expectation: .restatementOrGeneric
        ),
        autocomplete(
            "autocomplete-restatement-008", .personalMessage,
            context: "WHEN IM CLEAR ABOUT THE GOAL we move faster",
            output: "When I’m clear about the goal, the team can move.",
            expected: nil,
            expectation: .restatementOrGeneric
        ),
        autocomplete(
            "autocomplete-unsafe-001", .projectSummary,
            context: "The next section should",
            output: "**summarize the result**",
            expected: nil,
            expectation: .unsafe
        ),
        autocomplete(
            "autocomplete-unsafe-002", .email,
            context: "For more details visit",
            output: "[the guide](https://example.com)",
            expected: nil,
            expectation: .unsafe
        ),
        autocomplete(
            "autocomplete-unsafe-003", .personalMessage,
            context: "Please contact",
            output: "writer@example.com tomorrow",
            expected: nil,
            expectation: .unsafe
        ),
        autocomplete(
            "autocomplete-unsafe-004", .workUpdate,
            context: "The status remains",
            output: "safe\u{202E}hidden",
            expected: nil,
            expectation: .unsafe
        ),
        autocomplete(
            "autocomplete-unsafe-005", .meetingNote,
            context: "The note should stay",
            output: "clear\u{0000}today",
            expected: nil,
            expectation: .unsafe
        ),
        autocomplete(
            "autocomplete-unsafe-006", .planningNote,
            context: "The next task",
            output: "starts today\nand ends tomorrow",
            expected: nil,
            expectation: .unsafe
        ),
        autocomplete(
            "autocomplete-unsafe-007", .projectSummary,
            context: "The preview should remain",
            output: "<strong>short and clear</strong>",
            expected: nil,
            expectation: .unsafe
        ),
        autocomplete(
            "autocomplete-unsafe-008", .longForm,
            context: "The report concludes",
            output: "with a broad and generic discussion that repeats the topic, summarizes every earlier point, introduces a new recommendation, and continues far beyond one short useful clause for the person who is still writing the original paragraph.",
            expected: nil,
            expectation: .unsafe
        ),
    ]
}
