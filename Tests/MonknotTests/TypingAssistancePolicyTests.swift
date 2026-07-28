import Foundation
import XCTest
@testable import MonknotCore

final class TypingAssistancePolicyTests: XCTestCase {
    func testSchedulerKeepsTypingSilentAndPauseSuggestionOnly() {
        let text = "This are not working."
        let snapshot = TypingAssistanceEditorSnapshot(
            documentID: "note.md",
            revision: 1,
            text: text,
            cursorUTF16Offset: (text as NSString).length
        )
        let scheduler = TypingAssistanceScheduler()
        let typing = scheduler.decide(
            TypingAssistanceEditorEvent(
                sequenceID: "note.md",
                snapshot: snapshot,
                kind: .textChange,
                contentMode: .prose,
                interKeyMilliseconds: 58
            )
        )
        let pause = scheduler.decide(
            TypingAssistanceEditorEvent(
                sequenceID: "note.md",
                snapshot: snapshot,
                kind: .pause,
                contentMode: .prose,
                idleMilliseconds: 350
            )
        )

        XCTAssertEqual(typing.intent, .silent)
        XCTAssertFalse(typing.modelCallAllowed)
        XCTAssertTrue(typing.editorTextUnchanged)
        XCTAssertEqual(pause.intent, .pauseGrammar)
        XCTAssertTrue(pause.modelCallAllowed)
        XCTAssertFalse(pause.automaticApplicationAllowed)
    }

    func testCorrectionContextUsesCurrentParagraphOnly() {
        let text = "Earlier paragraph.\nThis are not working.\nNext paragraph."
        let cursor = ("Earlier paragraph.\nThis are not working." as NSString).length
        let snapshot = TypingAssistanceEditorSnapshot(
            documentID: "note.md",
            revision: 4,
            text: text,
            cursorUTF16Offset: cursor
        )

        let context = TypingAssistanceContextExtractor.correctionContext(for: snapshot)

        XCTAssertEqual(context?.text, "This are not working.")
        XCTAssertEqual(
            context?.range,
            NSRange(
                location: ("Earlier paragraph.\n" as NSString).length,
                length: ("This are not working." as NSString).length
            )
        )
    }

    func testCompletionContextExcludesTextAfterCaret() {
        let text = "Please review today"
        let cursor = ("Please review " as NSString).length
        let snapshot = TypingAssistanceEditorSnapshot(
            documentID: "note.md",
            revision: 1,
            text: text,
            cursorUTF16Offset: cursor
        )

        XCTAssertEqual(
            TypingAssistanceContextExtractor.completionContext(for: snapshot)?.text,
            "Please review "
        )
    }

    func testApplicationRequiresExactEditorState() {
        let source = "please send the report"
        let snapshot = TypingAssistanceEditorSnapshot(
            documentID: "note.md",
            revision: 3,
            text: source,
            cursorUTF16Offset: (source as NSString).length
        )
        let suggestion = TypingAssistanceSuggestion(
            requestKind: .grammar,
            sourceDocumentID: snapshot.documentID,
            sourceRevision: snapshot.revision,
            sourceText: snapshot.text,
            sourceCursorUTF16Offset: snapshot.cursorUTF16Offset,
            sourceSelectionUTF16Location: snapshot.selectionUTF16Location,
            sourceSelectionLength: snapshot.selectionLength,
            replacementRange: NSRange(location: 0, length: (source as NSString).length),
            replacementText: "Please send the report.",
            model: "local",
            latencyMilliseconds: 10
        )

        let accepted = TypingAssistanceAcceptancePolicy.apply(suggestion, to: snapshot)
        let stale = TypingAssistanceAcceptancePolicy.apply(
            suggestion,
            to: TypingAssistanceEditorSnapshot(
                documentID: "note.md",
                revision: 4,
                text: source + " now",
                cursorUTF16Offset: (source as NSString).length + 4
            )
        )

        XCTAssertTrue(accepted.accepted)
        XCTAssertEqual(accepted.text, "Please send the report.")
        XCTAssertFalse(stale.accepted)
        XCTAssertEqual(stale.rejection, .revisionChanged)
        XCTAssertEqual(stale.text, source + " now")
    }

    func testApplicationRejectsSameCaretWithDifferentSelectionLength() {
        let source = "Please send the report."
        let cursor = (source as NSString).length
        let originatingSnapshot = TypingAssistanceEditorSnapshot(
            documentID: "note.md",
            revision: 3,
            text: source,
            cursorUTF16Offset: cursor
        )
        let suggestion = TypingAssistanceSuggestion(
            requestKind: .grammar,
            sourceDocumentID: originatingSnapshot.documentID,
            sourceRevision: originatingSnapshot.revision,
            sourceText: originatingSnapshot.text,
            sourceCursorUTF16Offset: originatingSnapshot.cursorUTF16Offset,
            sourceSelectionUTF16Location:
                originatingSnapshot.selectionUTF16Location,
            sourceSelectionLength: originatingSnapshot.selectionLength,
            replacementRange: NSRange(location: 0, length: cursor),
            replacementText: "Please send the report.",
            model: "local",
            latencyMilliseconds: 10
        )
        let changedSelection = TypingAssistanceEditorSnapshot(
            documentID: originatingSnapshot.documentID,
            revision: originatingSnapshot.revision,
            text: originatingSnapshot.text,
            cursorUTF16Offset: cursor,
            selectionLength: 7
        )

        let result = TypingAssistanceAcceptancePolicy.apply(
            suggestion,
            to: changedSelection
        )

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.rejection, .selectionChanged)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(
            result.selectedRange,
            NSRange(location: cursor - 7, length: 7)
        )
    }

    func testCompletionApplicationPreservesSuffixSpacing() {
        let text = "Please review today"
        let cursor = ("Please review " as NSString).length
        let snapshot = TypingAssistanceEditorSnapshot(
            documentID: "note.md",
            revision: 2,
            text: text,
            cursorUTF16Offset: cursor
        )
        let suggestion = TypingAssistanceSuggestion(
            requestKind: .completion,
            sourceDocumentID: snapshot.documentID,
            sourceRevision: snapshot.revision,
            sourceText: snapshot.text,
            sourceCursorUTF16Offset: snapshot.cursorUTF16Offset,
            sourceSelectionUTF16Location: snapshot.selectionUTF16Location,
            sourceSelectionLength: snapshot.selectionLength,
            replacementRange: NSRange(location: cursor, length: 0),
            replacementText: "notes",
            model: "local",
            latencyMilliseconds: 10
        )

        let result = TypingAssistanceAcceptancePolicy.apply(suggestion, to: snapshot)

        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.text, "Please review notes today")
    }

    func testBoundaryCorrectorAppliesOnlyStandaloneKnownTypos() {
        let corrector = TypingAssistanceWordBoundaryCorrector()
        let typo = TypingAssistanceEditorSnapshot(
            documentID: "note.md",
            revision: 1,
            text: "teh ",
            cursorUTF16Offset: 4
        )
        let identifier = TypingAssistanceEditorSnapshot(
            documentID: "note.md",
            revision: 2,
            text: "teh_value ",
            cursorUTF16Offset: 10
        )

        XCTAssertEqual(
            corrector.edit(for: typo),
            TypingAssistanceTextEdit(
                range: NSRange(location: 0, length: 3),
                replacementText: "the"
            )
        )
        XCTAssertNil(corrector.edit(for: identifier))
    }

    func testBoundaryCorrectorLeavesCodeAndCommandsUnchanged() {
        let corrector = TypingAssistanceWordBoundaryCorrector()
        let technicalContexts = [
            "```\nteh ",
            "````\n```\nteh ",
            "$ teh ",
            "$teh ",
            "    teh ",
            "git teh ",
            "npm teh ",
            "cargo teh ",
            "kubectl teh ",
            "swift teh ",
            "cd teh ",
            "echo \"teh ",
            "curl -o teh ",
            "wget teh ",
            "printf teh ",
            "source setup.sh teh ",
            "export TEH ",
            "./deploy.sh teh ",
            "value = teh ",
            "render(teh ",
            "/tmp/teh ",
            "C:\\work\\teh ",
            "https://example.com/teh ",
            "ssh://example.com/teh ",
            "$env:teh ",
            "urn:example:teh ",
            "data:text/plain,teh ",
            "--teh ",
            "NODE_ENV=teh ",
            "`teh ",
            "``teh`` ",
        ]

        for (revision, text) in technicalContexts.enumerated() {
            XCTAssertNil(
                corrector.edit(
                    for: TypingAssistanceEditorSnapshot(
                        documentID: "note.md",
                        revision: revision,
                        text: text,
                        cursorUTF16Offset: (text as NSString).length
                    )
                ),
                "Changed code-like text: \(text)"
            )
        }
    }

    func testBoundaryCorrectorDoesNotEditInsideBracedParameterExpansion() {
        let corrector = TypingAssistanceWordBoundaryCorrector()
        let text = "${NAME:-fallback teh value}"
        let typoRange = (text as NSString).range(of: "teh")
        let snapshot = TypingAssistanceEditorSnapshot(
            documentID: "note.md",
            revision: 1,
            text: text,
            cursorUTF16Offset: NSMaxRange(typoRange) + 1
        )

        XCTAssertNil(corrector.edit(for: snapshot))
    }

    func testBoundaryCorrectorPreservesOrdinaryCommandMentions() {
        let corrector = TypingAssistanceWordBoundaryCorrector()
        let examples = [
            "git definately helps this workflow",
            "swift definately makes local builds easier",
            "open source definately matters here",
            "cd collections definately remain popular",
            "echo chambers definately distort discussion",
            "curl patterns definately appear in vector fields",
            "source material definately supports the conclusion",
            "export growth definately supports local jobs",
            "time definately flies during long reviews",
            "env settings definately belong in local configuration",
            "command wording definately matters in documentation",
        ]

        for (revision, text) in examples.enumerated() {
            let source = text as NSString
            let typoRange = source.range(of: "definately")
            let snapshot = TypingAssistanceEditorSnapshot(
                documentID: "note.md",
                revision: revision,
                text: text,
                cursorUTF16Offset: NSMaxRange(typoRange) + 1
            )

            XCTAssertEqual(
                corrector.edit(for: snapshot),
                TypingAssistanceTextEdit(
                    range: typoRange,
                    replacementText: "definitely"
                ),
                "Suppressed ordinary prose mentioning a tool: \(text)"
            )
        }
    }

    func testTechnicalClassifierRecognizesCompleteTechnicalContexts() {
        let contexts = [
            "git status",
            "git checkout feature/local-fix",
            "npm test",
            "npm ci",
            "cargo build --release",
            "kubectl get pods",
            "swift test",
            "cd project",
            "cd",
            "echo \"build complete\"",
            "curl https://example.com/archive",
            "wget https://example.com/archive",
            "printf \"%s\\n\" value",
            "source setup.sh",
            "export EDITOR=nano",
            "time swift test",
            "env DEBUG=1 npm test",
            "command git status",
            "python3 scripts/check.py",
            "./scripts/check.sh --verbose",
            "C:\\Tools\\formatter.exe --check",
            "\"C:\\Program Files\\Formatter\\format.exe\" --check",
            "EDITOR=nano swift build",
            "render(value)",
            "result = render(value)",
            "/Users/example/notes/todo.md",
            "https://example.com/docs",
            "ftp://example.com/releases",
            "ssh://example.com/repository",
            "C:\\Users\\example\\notes\\todo.md",
            "$PROJECT_ROOT",
            "${PROJECT_ROOT}",
            "$env:PROJECT_ROOT",
            "${PROJECT_ROOT:-/tmp/project}",
            "urn:example:project",
            "data:text/plain,example",
            "--verbose",
            "--verbose --force",
            "NODE_ENV=production",
            "`npm test`",
            "``npm `test` --silent``",
            "```\nnpm test\n```",
            "````swift\n```\nnpm test",
        ]

        for (revision, text) in contexts.enumerated() {
            XCTAssertTrue(
                TypingAssistanceTechnicalContextClassifier
                    .shouldSuppressAssistance(
                        in: TypingAssistanceEditorSnapshot(
                            documentID: "note.md",
                            revision: revision,
                            text: text,
                            cursorUTF16Offset: (text as NSString).length
                        )
                    ),
                "Did not classify technical context: \(text)"
            )
        }
    }

    func testTechnicalClassifierPreservesOrdinaryLowercaseProse() {
        let texts = [
            "teh feature is ready",
            "please run the test tomorrow",
            "we should update the package",
            "git is useful for this project",
            "git status is useful for checking changes",
            "npm packages are cached locally",
            "cargo shipments arrive tomorrow",
            "docker containers simplify local testing",
            "swift makes local development convenient",
            "open source software helps this project",
            "find the note before lunch",
            "cd collections remain popular",
            "echo chamber",
            "echo chambers distort the discussion",
            "curl pattern",
            "curl patterns appear in vector fields",
            "printf formatting improves diagnostics",
            "source text",
            "source material supports the conclusion",
            "export data",
            "export growth supports local jobs",
            "wget is the executable name in this sentence",
            "time flies during long reviews",
            "env settings belong in local configuration",
            "command wording matters in documentation",
            "please use render(value) after teh meeting",
        ]

        for (revision, text) in texts.enumerated() {
            XCTAssertFalse(
                TypingAssistanceTechnicalContextClassifier
                    .shouldSuppressAssistance(
                        in: TypingAssistanceEditorSnapshot(
                            documentID: "note.md",
                            revision: revision,
                            text: text,
                            cursorUTF16Offset: (text as NSString).length
                        )
                    ),
                "Misclassified lowercase prose: \(text)"
            )
        }
    }

    func testTechnicalClassifierOnlySuppressesTechnicalTargetsWithinProse() {
        let examples = [
            ("Please run `npm test` after teh meeting.", "npm", "teh"),
            (
                "Visit https://example.com after teh meeting.",
                "https://example.com",
                "teh"
            ),
            ("Open /tmp/result.txt after teh meeting.", "/tmp/result.txt", "teh"),
            ("Use --verbose if teh build fails.", "--verbose", "teh"),
            ("Read $PROJECT_ROOT before teh build.", "$PROJECT_ROOT", "teh"),
            (
                "Read $env:PROJECT_ROOT before teh build.",
                "$env:PROJECT_ROOT",
                "teh"
            ),
            (
                "Use ${NAME:-default} before teh build.",
                "${NAME:-default}",
                "teh"
            ),
            (
                "Reference urn:example:project after teh meeting.",
                "urn:example:project",
                "teh"
            ),
            (
                "Embed data:text/plain,example after teh meeting.",
                "data:text/plain,example",
                "teh"
            ),
            (
                "Open C:\\Users\\sam\\notes.txt after teh meeting.",
                "C:\\Users\\sam\\notes.txt",
                "teh"
            ),
            (
                "Use ssh://example.com/repo after teh meeting.",
                "ssh://example.com/repo",
                "teh"
            ),
            (
                "Run ``npm `test` --silent`` after teh meeting.",
                "npm `test` --silent",
                "teh"
            ),
        ]

        for (revision, example) in examples.enumerated() {
            let source = example.0 as NSString
            let snapshot = TypingAssistanceEditorSnapshot(
                documentID: "note.md",
                revision: revision,
                text: example.0,
                cursorUTF16Offset: source.length
            )

            XCTAssertFalse(
                TypingAssistanceTechnicalContextClassifier
                    .shouldSuppressAssistance(in: snapshot)
            )
            XCTAssertTrue(
                TypingAssistanceTechnicalContextClassifier
                    .shouldSuppressAssistance(
                        in: snapshot,
                        targetRange: source.range(of: example.1)
                    )
            )
            XCTAssertFalse(
                TypingAssistanceTechnicalContextClassifier
                    .shouldSuppressAssistance(
                        in: snapshot,
                        targetRange: source.range(of: example.2)
                    )
            )
        }
    }

    func testTechnicalClassifierFailsClosedForMalformedTargetRanges() {
        let text = "🙂 Read $env:PROJECT_ROOT after teh meeting."
        let sourceUTF16Length = text.utf16.count
        let snapshot = TypingAssistanceEditorSnapshot(
            documentID: "note.md",
            revision: 1,
            text: text,
            cursorUTF16Offset: sourceUTF16Length
        )
        let malformedRanges = [
            NSRange(location: -1, length: 1),
            NSRange(location: 0, length: -1),
            NSRange(location: sourceUTF16Length + 1, length: 0),
            NSRange(location: 1, length: Int.max),
            NSRange(location: Int.max, length: Int.max),
        ]

        for range in malformedRanges {
            XCTAssertTrue(
                TypingAssistanceTechnicalContextClassifier
                    .shouldSuppressAssistance(
                        in: snapshot,
                        targetRange: range
                    )
            )
        }

        let source = text as NSString
        XCTAssertTrue(
            TypingAssistanceTechnicalContextClassifier
                .shouldSuppressAssistance(
                    in: snapshot,
                    targetRange: source.range(of: "$env:PROJECT_ROOT")
                )
        )
        XCTAssertFalse(
            TypingAssistanceTechnicalContextClassifier
                .shouldSuppressAssistance(
                    in: snapshot,
                    targetRange: source.range(of: "teh")
                )
        )
    }

    func testConditionalWrappersRequireCredibleInvocation() {
        let commands = [
            "time swift test",
            "env DEBUG=1 npm test",
            "env -i",
            "command git status",
            "command -v git",
        ]
        let prose = [
            "time flies during long reviews",
            "env settings belong in local configuration",
            "command wording matters in documentation",
        ]

        for text in commands {
            XCTAssertTrue(
                TypingAssistanceTechnicalContextClassifier
                    .shouldSuppressAssistance(
                        in: TypingAssistanceEditorSnapshot(
                            documentID: "note.md",
                            revision: 1,
                            text: text,
                            cursorUTF16Offset: text.utf16.count
                        )
                    ),
                "Did not classify wrapped command: \(text)"
            )
        }
        for text in prose {
            XCTAssertFalse(
                TypingAssistanceTechnicalContextClassifier
                    .shouldSuppressAssistance(
                        in: TypingAssistanceEditorSnapshot(
                            documentID: "note.md",
                            revision: 1,
                            text: text,
                            cursorUTF16Offset: text.utf16.count
                        )
                    ),
                "Misclassified wrapper prose: \(text)"
            )
        }
    }

    func testTechnicalClassifierUsesSameLineSemanticsForSpecificTargets() {
        let examples = [
            ("git checkout main", "main"),
            ("npm ci", "ci"),
            ("swift teh", "teh"),
            ("./scripts/check.sh value", "value"),
            ("C:\\Tools\\formatter.exe input", "input"),
        ]

        for (revision, example) in examples.enumerated() {
            let source = example.0 as NSString
            let snapshot = TypingAssistanceEditorSnapshot(
                documentID: "note.md",
                revision: revision,
                text: example.0,
                cursorUTF16Offset: source.length
            )

            XCTAssertTrue(
                TypingAssistanceTechnicalContextClassifier
                    .shouldSuppressAssistance(in: snapshot)
            )
            XCTAssertTrue(
                TypingAssistanceTechnicalContextClassifier
                    .shouldSuppressAssistance(
                        in: snapshot,
                        targetRange: source.range(of: example.1)
                    )
            )
        }
    }

    func testTechnicalClassifierHonorsMarkdownDelimiterLengths() {
        let unterminatedOuterFences = [
            "````swift\n```\nteh prose",
            "~~~~\n~~~\nteh prose",
        ]

        for (revision, text) in unterminatedOuterFences.enumerated() {
            XCTAssertTrue(
                TypingAssistanceTechnicalContextClassifier
                    .shouldSuppressAssistance(
                        in: TypingAssistanceEditorSnapshot(
                            documentID: "note.md",
                            revision: revision,
                            text: text,
                            cursorUTF16Offset: (text as NSString).length
                        )
                    )
            )
        }

        let closedFence = "````swift\n```\n````\nteh prose"
        XCTAssertFalse(
            TypingAssistanceTechnicalContextClassifier
                .shouldSuppressAssistance(
                    in: TypingAssistanceEditorSnapshot(
                        documentID: "note.md",
                        revision: 3,
                        text: closedFence,
                        cursorUTF16Offset: (closedFence as NSString).length
                    )
                )
        )
    }

    func testSafetyPolicyRejectsProtectedAndMeaningChanges() {
        XCTAssertFalse(
            TypingAssistanceSafetyPolicy.allowsCorrection(
                original: "Visit https://docs.example.dev before you starts.",
                corrected: "Before you start."
            )
        )
        XCTAssertFalse(
            TypingAssistanceSafetyPolicy.allowsCorrection(
                original: "Updates may arrive later.",
                corrected: "Updates must arrive later."
            )
        )
        XCTAssertFalse(
            TypingAssistanceSafetyPolicy.allowsCorrection(
                original: "A scheduler require checks.",
                corrected: "You need checks."
            )
        )
        XCTAssertFalse(
            TypingAssistanceSafetyPolicy.allowsCorrection(
                original: "this are not working.",
                corrected: "these are not working."
            )
        )
        XCTAssertFalse(
            TypingAssistanceSafetyPolicy.allowsCorrection(
                original: "The model is ready.",
                corrected: "The models are ready."
            )
        )
    }

    func testSafetyPolicyAllowsLocalCorrectionAndContractionExpansion() {
        XCTAssertTrue(
            TypingAssistanceSafetyPolicy.allowsCorrection(
                original: "The scheduler requries checks.",
                corrected: "The scheduler requires checks."
            )
        )
        XCTAssertTrue(
            TypingAssistanceSafetyPolicy.allowsCorrection(
                original: "This app dosnt work.",
                corrected: "This app does not work."
            )
        )
        XCTAssertTrue(
            TypingAssistanceSafetyPolicy.allowsCorrection(
                original: "The tasks is ready.",
                corrected: "The tasks are ready."
            )
        )
        XCTAssertTrue(
            TypingAssistanceSafetyPolicy.allowsCorrection(
                original: "This are not working.",
                corrected: "This is not working."
            )
        )
    }
}
