import Foundation
import XCTest
@testable import MonknotCore

final class FlowMarkdownBlockProtectedRangeTests: FlowProtectedRangeTestCase {
    func testMarkdownProtectsClosedAndUnterminatedFencedCodeBlocks() {
        let markdown = """
        Before.

        ```swift
        let value = 1
        ````

        Between.

        ~~~text
        unfinished
        """

        XCTAssertEqual(
            protectedSubstrings(in: markdown),
            [
                "```swift\nlet value = 1\n````\n",
                "~~~text\nunfinished",
            ]
        )
    }

    func testMarkdownProtectsFencedCodeInsideNestedContainerPrefixes() {
        let markdown = """
        > ~~~
        > quoted teh
        > ~~~
        Editable quote aftermath.

        > > 1. ```swift
        > >    let teh = 1
        > >    ```
        Editable nested aftermath.
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for block in [
            "> ~~~\n> quoted teh\n> ~~~\n",
            "> > 1. ```swift\n> >    let teh = 1\n> >    ```\n",
        ] {
            let blockRange = source.range(of: block)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, blockRange).length == blockRange.length
            }, "Expected the container fence to protect its complete block")
        }
        for prose in ["Editable quote aftermath.", "Editable nested aftermath."] {
            let proseRange = source.range(of: prose)
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, proseRange).length > 0
            }, "Expected prose after the closed container fence to remain editable")
        }
    }

    func testMarkdownFencesStopAtContainerExitAndLaterBlocksPairIndependently() {
        let markdown = """
        > ```
        > first quoted code
        Outside the first quote.
        > ```
        > second quoted code
        > ```
        After quoted blocks.

        - ```
          first listed code
        Outside the first list.
        - ```
          second listed code
          ```
        After listed blocks.
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for code in [
            "first quoted code",
            "second quoted code",
            "first listed code",
            "second listed code",
        ] {
            let codeRange = source.range(of: code)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, codeRange).length == codeRange.length
            }, "Expected \(code) to be protected")
        }
        for prose in [
            "Outside the first quote.",
            "After quoted blocks.",
            "Outside the first list.",
            "After listed blocks.",
        ] {
            let proseRange = source.range(of: prose)
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, proseRange).length > 0
            }, "Expected \(prose) to remain editable")
        }
    }

    func testMarkdownFencesReplayListAndBlockquoteContainersInOriginalOrder() {
        let markdown = """
        - > ```
          > listed quoted code
          > ```
        Editable after list quote.

        > - > ~~~
        >   > alternating container code
        >   > ~~~
        Editable after alternating containers.
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for code in ["listed quoted code", "alternating container code"] {
            let codeRange = source.range(of: code)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, codeRange).length == codeRange.length
            }, "Expected ordered container fence body \(code) to be protected")
        }
        for prose in ["Editable after list quote.", "Editable after alternating containers."] {
            let proseRange = source.range(of: prose)
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, proseRange).length > 0
            }, "Expected \(prose) to remain editable")
        }
    }

    func testMarkdownProtectsInlineCodeSpans() {
        let markdown = "Edit `one()` and ``a ` nested tick`` but not \\`escaped."

        XCTAssertEqual(
            protectedSubstrings(in: markdown),
            ["`one()`", "``a ` nested tick``", "\\`"]
        )
    }

    func testMarkdownProtectsUnterminatedInlineCodeWhileTyping() {
        let markdown = "Type `teh"

        XCTAssertTrue(
            service.protectedRanges(in: markdown, mode: .markdown).contains {
                NSMaxRange($0) == (markdown as NSString).length &&
                    NSLocationInRange((markdown as NSString).range(of: "teh").location, $0)
            }
        )
    }

    func testMarkdownCompletedWikilinkAliasLeavesAliasProseEditable() {
        let markdown = "See [[Daily Note#Plan|today's editable alias]] afterward."
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for syntax in ["[[", "Daily Note#Plan", "|", "]]" ] {
            let syntaxRange = source.range(of: syntax)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, syntaxRange).length == syntaxRange.length
            }, "Expected \(syntax) to remain protected")
        }
        for prose in ["today's editable alias", "afterward"] {
            let proseRange = source.range(of: prose)
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, proseRange).length > 0
            }, "Expected \(prose) to remain editable")
        }
    }

    func testMarkdownProtectsStructuralDelimitersButLeavesProseEditable() {
        let markdown = "# **Editable** [label](Guide.md)"
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)
        let source = markdown as NSString

        for marker in ["#", "**", "[", "](", ")"] {
            let markerRange = source.range(of: marker)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, markerRange).length == markerRange.length
            })
        }
        let editableRange = source.range(of: "Editable")
        XCTAssertFalse(ranges.contains {
            NSIntersectionRange($0, editableRange).length > 0
        })
    }

    func testMarkdownLeavesOrdinaryPunctuationEditableAndProtectsLineSyntax() {
        let markdown = """
        Wow! (ordinary_prose) uses #hashtags and a | pipe.
        # Heading
        - [x] Task
        1. Item
        > Quote
        ---
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)
        let proseRange = source.range(of: "Wow! (ordinary_prose) uses #hashtags and a | pipe.")

        XCTAssertFalse(ranges.contains {
            NSIntersectionRange($0, proseRange).length > 0
        })
        for marker in ["# Heading", "- [x] Task", "1. Item", "> Quote", "---"] {
            let lineRange = source.range(of: marker)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, lineRange).length > 0
            }, "Expected syntax in \(marker) to be protected")
        }
    }

    func testMarkdownOnlyTreatsIndentedLinesAtBlockBoundariesAsCode() {
        let continuedParagraph = "Paragraph\n    continued prose"
        let continuedRange = (continuedParagraph as NSString).range(of: "continued prose")
        XCTAssertFalse(service.protectedRanges(in: continuedParagraph, mode: .markdown).contains {
            NSIntersectionRange($0, continuedRange).length > 0
        })

        let afterHeading = "# Heading\n    let teh = 1\nEditable"
        let afterHeadingSource = afterHeading as NSString
        let afterHeadingRanges = service.protectedRanges(in: afterHeading, mode: .markdown)
        let codeRange = afterHeadingSource.range(of: "let teh = 1")
        XCTAssertTrue(afterHeadingRanges.contains {
            NSIntersectionRange($0, codeRange).length == codeRange.length
        })
        let editableRange = afterHeadingSource.range(of: "Editable")
        XCTAssertFalse(afterHeadingRanges.contains {
            NSIntersectionRange($0, editableRange).length > 0
        })

        let code = "    let value = 1"
        XCTAssertEqual(protectedSubstrings(in: code), [code])
    }

    func testMarkdownRecognizesIndentedCodeRelativeToQuoteAndListContainers() {
        let markdown = """
        >     let quotedTeh = 1
        >     let quotedValue = 2
        > Ordinary quoted prose.

        - List item

            ordinary list continuation prose
        -     let listedTeh = 2
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for code in ["let quotedTeh = 1", "let quotedValue = 2", "let listedTeh = 2"] {
            let codeRange = source.range(of: code)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, codeRange).length == codeRange.length
            }, "Expected container-relative code \(code) to be protected")
        }
        for prose in ["Ordinary quoted prose.", "ordinary list continuation prose"] {
            let proseRange = source.range(of: prose)
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, proseRange).length > 0
            }, "Expected \(prose) to remain editable")
        }
    }

    func testMarkdownRecognizesTablesOnlyWithHeaderAndSeparatorRows() {
        let markdown = """
        Name | Value
        --- | :---:
        One | Two

        A | B | ordinary prose
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for syntax in ["Name | Value", "--- | :---:", "One | Two"] {
            let line = source.range(of: syntax)
            let pipe = source.range(of: "|", options: [], range: line)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, pipe).length == pipe.length
            }, "Expected the table pipe in \(syntax) to be protected")
        }
        let separator = source.range(of: "--- | :---:")
        XCTAssertTrue(ranges.contains {
            NSIntersectionRange($0, separator).length == separator.length
        })
        let prose = source.range(of: "A | B | ordinary prose")
        XCTAssertFalse(ranges.contains {
            NSIntersectionRange($0, prose).length > 0
        })
    }

    func testMarkdownProtectsFootnoteAndReferenceIdentifiersButNotLabelsOrBody() {
        let markdown = """
        Use [^note] and [visible label][guide].

        [^note]: Footnote body stays editable.
        [guide]: Guide.md
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for identifier in ["[^note]", "[^note]:", "[guide]:"] {
            let identifierRange = source.range(of: identifier, options: identifier.hasSuffix(":") ? [.backwards] : [])
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, identifierRange).length == identifierRange.length
            }, "Expected \(identifier) to be protected")
        }
        let usage = source.range(of: "[visible label][guide]")
        let referenceIdentifier = source.range(
            of: "guide",
            options: [],
            range: usage
        )
        XCTAssertTrue(ranges.contains {
            NSIntersectionRange($0, referenceIdentifier).length == referenceIdentifier.length
        })
        for editable in ["visible label", "Footnote body stays editable."] {
            let editableRange = source.range(of: editable)
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, editableRange).length > 0
            }, "Expected \(editable) to remain editable")
        }
    }

    func testMarkdownHandlesWhitespaceAndEmptyBlockquoteLines() {
        let markdown = "  \n>\n> \nProse"

        let ranges = service.protectedRanges(in: markdown, mode: .markdown)
        let source = markdown as NSString
        for marker in [source.range(of: ">"), source.range(of: ">", options: [], range: NSRange(location: 4, length: 2))] {
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, marker).length == marker.length
            })
        }
    }
}
