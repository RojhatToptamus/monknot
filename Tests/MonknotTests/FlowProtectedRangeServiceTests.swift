import Foundation
import XCTest
@testable import MonknotCore

final class FlowProtectedRangeServiceTests: XCTestCase {
    private let service = FlowProtectedRangeService()

    func testMarkdownProtectsYAMLFrontMatterOnlyAtDocumentStart() {
        let markdown = """
        ---
        title: Draft
        tags: [flow]
        ---
        Editable prose.

        ---
        Not front matter.
        ---
        """

        XCTAssertEqual(
            protectedSubstrings(in: markdown),
            ["---\ntitle: Draft\ntags: [flow]\n---\n", "---", "---"]
        )
    }

    func testMarkdownProtectsUnterminatedFrontMatter() {
        let markdown = """
        ---
        title: Draft
        unfinished metadata
        """

        XCTAssertEqual(protectedSubstrings(in: markdown), [markdown])
    }

    func testMarkdownUsesFrontMatterBodyEvidenceOnlyForAnUnclosedOpener() {
        let unclosed = """
        ---
        Ordinary prose continues.
        More prose.
        """
        let unclosedSource = unclosed as NSString
        let unclosedRanges = service.protectedRanges(in: unclosed, mode: .markdown)

        XCTAssertEqual(protectedSubstrings(in: unclosed), ["---"])
        XCTAssertFalse(unclosedRanges.contains {
            NSIntersectionRange($0, unclosedSource.range(of: "Ordinary prose continues.")).length > 0
        })

        let closed = """
        ---
        Ordinary root scalar
        ---
        Editable after front matter.
        """
        let closedSource = closed as NSString
        let closedRanges = service.protectedRanges(in: closed, mode: .markdown)
        let frontMatter = closedSource.range(of: "---\nOrdinary root scalar\n---\n")
        XCTAssertTrue(closedRanges.contains {
            NSIntersectionRange($0, frontMatter).length == frontMatter.length
        })
        XCTAssertFalse(closedRanges.contains {
            NSIntersectionRange($0, closedSource.range(of: "Editable after front matter.")).length > 0
        })
    }

    func testMarkdownProtectsClosedYAMLRootListFrontMatter() {
        let markdown = """
        ---
        - first
        - second
        ...
        Editable prose.
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)
        let frontMatter = source.range(of: "---\n- first\n- second\n...\n")

        XCTAssertTrue(ranges.contains {
            NSIntersectionRange($0, frontMatter).length == frontMatter.length
        })
        XCTAssertFalse(ranges.contains {
            NSIntersectionRange($0, source.range(of: "Editable prose.")).length > 0
        })
    }

    func testMarkdownProtectsTOMLFrontMatter() {
        let markdown = """
        +++
        title = "Draft"
        [flow]
        enabled = true
        +++
        Editable prose.
        """

        XCTAssertEqual(
            protectedSubstrings(in: markdown),
            ["+++\ntitle = \"Draft\"\n[flow]\nenabled = true\n+++\n"]
        )
    }

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

    func testMarkdownProtectsIncompleteLinkDestinationsWhileTyping() {
        for markdown in ["[label](docs/teh", "Open [[teh", "Open [[target|unfinished alias"] {
            let destinationRange = (markdown as NSString).range(of: "teh")
            let protectedRange = destinationRange.location == NSNotFound
                ? (markdown as NSString).range(of: "unfinished alias")
                : destinationRange
            XCTAssertTrue(
                service.protectedRanges(in: markdown, mode: .markdown).contains {
                    NSIntersectionRange($0, protectedRange).length == protectedRange.length
                },
                "Expected the unfinished destination in \(markdown) to be protected"
            )
        }
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

    func testMarkdownRequiresAnUnescapedOpeningBracketForLinkDestination() {
        XCTAssertEqual(protectedSubstrings(in: "array](ordinary prose)"), [])
        XCTAssertEqual(protectedSubstrings(in: #"\[label](ordinary prose)"#), [#"\["#])

        let markdown = "[outer [inner]](docs/file.md)"
        let destination = (markdown as NSString).range(of: "docs/file.md")
        XCTAssertTrue(service.protectedRanges(in: markdown, mode: .markdown).contains {
            NSIntersectionRange($0, destination).length == destination.length
        })
    }

    func testMarkdownIgnoresIncompleteDestinationExamplesInsideCode() {
        let markdown = """
        Inline `Open [[unfinished` editable after wikilink example.
        Inline `[label](unfinished` editable after link example.

        ```markdown
        Open [[unfinished
        [label](unfinished
        ```
        Editable after fenced examples.
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for prose in [
            "editable after wikilink example.",
            "editable after link example.",
            "Editable after fenced examples.",
        ] {
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

    func testMarkdownProtectsNestedAndEscapedDestinationParentheses() {
        for markdown in [
            "[label](docs/foo(bar).md)",
            #"[label](docs/foo\(bar\).md)"#,
        ] {
            let source = markdown as NSString
            let destinationRange = source.range(of: "docs")
            let ranges = service.protectedRanges(in: markdown, mode: .markdown)
            XCTAssertTrue(ranges.contains {
                NSLocationInRange(destinationRange.location, $0) && NSMaxRange($0) == source.length
            }, "Expected the complete destination in \(markdown) to be protected")
        }
    }

    func testMarkdownProtectsIndentedAndHTMLCodeContents() {
        let markdown = """
        Prose

            let teh = value
        <pre>teh <strong>code</strong></pre>
        <code>inline teh</code>
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for code in ["let teh = value", "teh <strong>code</strong>", "inline teh"] {
            let codeRange = source.range(of: code)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, codeRange).length == codeRange.length
            }, "Expected \(code) to be protected")
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

    func testMarkdownProtectsNestedPrefixesClosingATXMarkersAndLongEmphasisRuns() {
        let markdown = """
        >   - [ ] # Nested heading ###
        ****bold**** and café_culture
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for marker in [">", "-", "[ ]", "#", "###", "****"] {
            let markerRange = source.range(of: marker)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, markerRange).length == markerRange.length
            }, "Expected \(marker) to be protected")
        }
        let closingEmphasis = source.range(
            of: "****",
            options: [.backwards],
            range: NSRange(location: 0, length: source.length)
        )
        XCTAssertTrue(ranges.contains {
            NSIntersectionRange($0, closingEmphasis).length == closingEmphasis.length
        })
        let intrawordUnderscore = source.range(of: "café_culture")
        XCTAssertFalse(ranges.contains {
            NSIntersectionRange($0, intrawordUnderscore).length > 0
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

    func testMarkdownProtectsWorkspaceLinkDestinationsFromSharedParser() {
        let markdown = """
        [guide](docs/Guide.md) [[Daily Note#Plan|today]] ![cover](images/cover.png) [use][ref]

        [ref]: references/Source.md
        """

        let links = MarkdownWorkspaceLinkParser().links(in: markdown)
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for link in links {
            XCTAssertTrue(
                ranges.contains { NSIntersectionRange($0, link.destinationRange.nsRange).length == link.destinationRange.length },
                "Expected \(link.destination) to be protected"
            )
        }
    }

    func testMarkdownProtectsRawAndAutolinkURLs() {
        let markdown = "Visit https://example.com/docs and <https://example.org/a?q=1>."

        XCTAssertEqual(
            protectedSubstrings(in: markdown),
            ["https://example.com/docs", "<https://example.org/a?q=1>"]
        )
    }

    func testProtectsIncompleteURLLikeFormsWhileTyping() {
        let text = "https:// www.exa mailto:user@ user@example"
        let source = text as NSString

        for mode in [FlowSourceMode.markdown, .plainText] {
            let ranges = service.protectedRanges(in: text, mode: mode)
            for token in ["https://", "www.exa", "mailto:user@", "user@example"] {
                let tokenRange = source.range(of: token)
                XCTAssertTrue(ranges.contains {
                    NSIntersectionRange($0, tokenRange).length == tokenRange.length
                }, "Expected \(token) to be protected in \(mode)")
            }
        }
    }

    func testProtectsIncompleteCustomSchemeURLsWithoutSwallowingFollowingProse() {
        let text = "Open monknot:// obsidian:// ssh:// file:// then ordinary prose remains editable."
        let source = text as NSString

        for mode in [FlowSourceMode.markdown, .plainText] {
            let ranges = service.protectedRanges(in: text, mode: mode)
            for token in ["monknot://", "obsidian://", "ssh://", "file://"] {
                let tokenRange = source.range(of: token)
                XCTAssertTrue(ranges.contains {
                    NSIntersectionRange($0, tokenRange).length == tokenRange.length
                }, "Expected \(token) to be protected in \(mode)")
            }
            let prose = source.range(of: "then ordinary prose remains editable.")
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, prose).length > 0
            })
        }
    }

    func testMarkdownProtectsHTMLTagsAndComments() {
        let markdown = "<section data-label=\">\">Editable</section> and <!-- protected\ncomment --> prose."

        XCTAssertEqual(
            protectedSubstrings(in: markdown),
            ["<section data-label=\">\">", "</section>", "<!-- protected\ncomment -->"]
        )
    }

    func testMarkdownCodeBlocksRequireAnExactHTMLClosingTagName() {
        let markdown = "<code>first </codeblock> still code</code> editable prose"
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)
        let code = source.range(of: "<code>first </codeblock> still code</code>")
        let prose = source.range(of: "editable prose")

        XCTAssertTrue(ranges.contains {
            NSIntersectionRange($0, code).length == code.length
        })
        XCTAssertFalse(ranges.contains {
            NSIntersectionRange($0, prose).length > 0
        })
    }

    func testMarkdownCodeBlocksRequireAnExactHTMLOpeningTagName() {
        let markdown = "<code-example>editable</code-example> <code>protected</code>"
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)
        let editable = source.range(of: "editable")
        let code = source.range(of: "<code>protected</code>")

        XCTAssertFalse(ranges.contains {
            NSIntersectionRange($0, editable).length > 0
        })
        XCTAssertTrue(ranges.contains {
            NSIntersectionRange($0, code).length == code.length
        })
    }

    func testMarkdownSelfClosingCodeAndPreTagsDoNotProtectFollowingProse() {
        let markdown = "<code />Editable after code. <pre/>Editable after pre."
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for tag in ["<code />", "<pre/>"] {
            let tagRange = source.range(of: tag)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, tagRange).length == tagRange.length
            }, "Expected \(tag) to be protected")
        }
        for prose in ["Editable after code.", "Editable after pre."] {
            let proseRange = source.range(of: prose)
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, proseRange).length > 0
            }, "Expected \(prose) to remain editable")
        }
    }

    func testMarkdownProtectsScriptAndStyleBodiesWithExactCaseInsensitiveTagNames() {
        let markdown = """
        <SCRIPT type="module">const teh = "</script-example>";</sCrIpT>
        Editable after script.
        <style>.teh { color: red; }</STYLE>
        Editable after style.
        <script-example>editable custom-element body</script-example>
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for body in ["const teh = \"</script-example>\";", ".teh { color: red; }"] {
            let bodyRange = source.range(of: body)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, bodyRange).length == bodyRange.length
            }, "Expected raw HTML body \(body) to be protected")
        }
        for prose in [
            "Editable after script.",
            "Editable after style.",
            "editable custom-element body",
        ] {
            let proseRange = source.range(of: prose)
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, proseRange).length > 0
            }, "Expected \(prose) to remain editable")
        }
    }

    func testMarkdownProtectsUnclosedScriptAndStyleBlocksConservatively() {
        for markdown in [
            "Before <script>const teh = 1",
            "Before <style>.teh { color: red; }",
        ] {
            let source = markdown as NSString
            let opening = source.range(of: "<")
            let protectedTail = NSRange(location: opening.location, length: source.length - opening.location)
            XCTAssertTrue(service.protectedRanges(in: markdown, mode: .markdown).contains {
                NSIntersectionRange($0, protectedTail).length == protectedTail.length
            })
        }
    }

    func testMarkdownHTMLScannerIgnoresTokensInsideMarkdownCode() {
        let markdown = """
        Inline `<pre>` example and `<!--` example. Editable after inline examples.

        ```html
        <pre>
        <!--
        ```
        Editable after fenced examples.
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for prose in ["Editable after inline examples.", "Editable after fenced examples."] {
            let proseRange = source.range(of: prose)
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, proseRange).length > 0
            }, "Expected \(prose) to remain editable")
        }
    }

    func testMarkdownHTMLScannerIgnoresTokensInsideIndentedCodeAndFrontMatter() {
        for markdown in [
            "    <pre>\nEditable after indented code.",
            "---\ntitle: \"<pre>\"\n---\nEditable after front matter.",
        ] {
            let source = markdown as NSString
            let prose = source.range(of: "Editable")
            XCTAssertFalse(service.protectedRanges(in: markdown, mode: .markdown).contains {
                NSIntersectionRange($0, prose).length > 0
            })
        }
    }

    func testMarkdownHTMLScannerDoesNotReparseNestedTokensInCommentsOrRawBlocks() {
        for markdown in [
            "<!-- mention <pre> -->\nEditable after comment.",
            "<script>const s = \"<pre>\"; const c = \"<!--\";</script>\nEditable after script.",
        ] {
            let source = markdown as NSString
            let prose = source.range(of: "Editable")
            XCTAssertFalse(service.protectedRanges(in: markdown, mode: .markdown).contains {
                NSIntersectionRange($0, prose).length > 0
            })
        }
    }

    func testPlainTextProtectsURLsButNotMarkdownSyntax() {
        let text = "`code` [guide](Guide.md) <em>tag</em> https://example.com/path"

        XCTAssertEqual(
            protectedSubstrings(in: text, mode: .plainText),
            ["https://example.com/path"]
        )
    }

    func testEnclosingRangeReturnsClippedDocumentRelativeIntersections() throws {
        let markdown = "Before `protected` after"
        let protectedRange = (markdown as NSString).range(of: "`protected`")
        let enclosingRange = NSRange(location: protectedRange.location + 2, length: protectedRange.length)

        let intersection = try XCTUnwrap(
            service.protectedRanges(
                in: markdown,
                mode: .markdown,
                intersecting: enclosingRange
            ).first
        )

        XCTAssertEqual(intersection.location, enclosingRange.location)
        XCTAssertEqual(intersection.length, protectedRange.length - 2)
        XCTAssertEqual((markdown as NSString).substring(with: intersection), "rotected`")
    }

    func testOverlappingAndAdjacentRangesAreMerged() {
        let markdown = "<https://example.com><!--comment--><strong>"

        XCTAssertEqual(
            service.protectedRanges(in: markdown, mode: .markdown),
            [NSRange(location: 0, length: (markdown as NSString).length)]
        )
    }

    func testRangesUseUTF16Coordinates() throws {
        let markdown = "😀 text [note](docs/📘.md) and `café`"
        let source = markdown as NSString
        let destination = source.range(of: "docs/📘.md")
        let code = source.range(of: "`café`")
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        XCTAssertTrue(ranges.contains {
            NSIntersectionRange($0, destination).length == destination.length
        })
        XCTAssertTrue(ranges.contains(code))
        XCTAssertEqual(destination.location, 15)
        XCTAssertEqual(destination.length, 10)
        XCTAssertEqual(source.substring(with: destination), "docs/📘.md")
    }

    func testCancellationDoesNotWaitForOneWholeDocumentURLMatch() async {
        let source = String(repeating: "https://example.com/path?x=1 ", count: 100_000)
        let task = Task.detached(priority: .utility) {
            FlowProtectedRangeService().protectedRanges(in: source, mode: .plainText)
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let cancellationStarted = Date()
        task.cancel()
        _ = await task.value

        XCTAssertLessThan(
            Date().timeIntervalSince(cancellationStarted),
            1.0,
            "URL detection should observe cancellation between bounded match calls."
        )
    }

    func testBoundedURLDetectionDoesNotSplitTokensAtChunkEdges() {
        let padding = String(repeating: "word ", count: 3_300)
        let url = "https://example.com/path"
        let text = padding + url
        let urlRange = (text as NSString).range(of: url)

        XCTAssertTrue(service.protectedRanges(in: text, mode: .plainText).contains {
            NSIntersectionRange($0, urlRange).length == urlRange.length
        })
    }

    func testOversizedURLTokenIsProtectedWithoutOneUnboundedDetectorCall() {
        let text = "monknot://" + String(repeating: "segment", count: 3_000)

        XCTAssertEqual(
            service.protectedRanges(in: text, mode: .plainText),
            [NSRange(location: 0, length: (text as NSString).length)]
        )
    }

    private func protectedSubstrings(
        in text: String,
        mode: FlowSourceMode = .markdown
    ) -> [String] {
        let source = text as NSString
        return service.protectedRanges(in: text, mode: mode).map {
            source.substring(with: $0)
        }
    }
}
