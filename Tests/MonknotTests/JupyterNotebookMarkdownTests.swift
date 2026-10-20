import Foundation
@testable import MonknotCore
import XCTest

final class JupyterNotebookMarkdownTests: XCTestCase {
    private func notebook(cells: [[String: Any]], metadata: [String: Any] = [:]) throws -> String {
        let object: [String: Any] = ["cells": cells, "metadata": metadata, "nbformat": 4, "nbformat_minor": 5]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testCellsBecomeMarkdownAndFencedCodeInTheKernelsLanguage() throws {
        let text = try notebook(
            cells: [
                ["cell_type": "markdown", "metadata": [:], "source": ["# Sales\n", "\n", "Quarterly **totals**."]],
                ["cell_type": "code", "metadata": [:], "execution_count": 1, "outputs": [],
                 "source": ["totals = df.groupby(\"q\").sum()\n", "totals"]],
                ["cell_type": "raw", "metadata": [:], "source": "raw text"],
            ],
            metadata: ["kernelspec": ["language": "R", "name": "ir"]]
        )

        XCTAssertEqual(
            JupyterNotebookMarkdown.markdown(fromNotebookText: text),
            "# Sales\n\nQuarterly **totals**.\n\n```r\ntotals = df.groupby(\"q\").sum()\ntotals\n```\n\n```\nraw text\n```\n"
        )
    }

    func testOutputsFollowTheirCell() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let text = try notebook(cells: [
            ["cell_type": "code", "metadata": [:], "execution_count": 2, "source": "run()",
             "outputs": [
                ["output_type": "stream", "name": "stdout", "text": ["step 1\n", "step 2\n"]],
                ["output_type": "execute_result", "execution_count": 2, "metadata": [:],
                 "data": ["text/plain": ["   q  total\n", "0  1     10"], "text/html": "<table></table>"]],
                ["output_type": "display_data", "metadata": [:],
                 "data": ["image/png": png + "\n", "text/plain": "<Figure>"]],
                ["output_type": "display_data", "metadata": [:], "data": ["text/markdown": "**Done**"]],
                ["output_type": "display_data", "metadata": [:], "data": ["text/html": "<div>chart</div>"]],
                ["output_type": "error", "ename": "ValueError", "evalue": "bad",
                 "traceback": ["\u{1B}[0;31mValueError\u{1B}[0m: bad"]],
             ]],
        ])

        let markdown = JupyterNotebookMarkdown.markdown(fromNotebookText: text)

        XCTAssertEqual(markdown, [
            "```python\nrun()\n```",
            "```output\nstep 1\nstep 2\n```",
            "```output\n   q  total\n0  1     10\n```",
            "![Output](data:image/png;base64,\(png))",
            "**Done**",
            "*This output is HTML, which Monknot does not show.*",
            "```output\nValueError: bad\n```",
        ].joined(separator: "\n\n") + "\n")
    }

    func testAFenceOutgrowsTheBackticksInTheCode() throws {
        let text = try notebook(cells: [
            ["cell_type": "code", "metadata": [:], "outputs": [], "source": "doc = \"\"\"\n```\nexample\n```\n\"\"\""],
        ])

        XCTAssertEqual(
            JupyterNotebookMarkdown.markdown(fromNotebookText: text),
            "````python\ndoc = \"\"\"\n```\nexample\n```\n\"\"\"\n````\n"
        )
    }

    func testALongOutputIsCutWithACount() throws {
        let lines = (1...250).map { "line \($0)\n" }
        let text = try notebook(cells: [
            ["cell_type": "code", "metadata": [:], "source": "",
             "outputs": [["output_type": "stream", "name": "stdout", "text": lines]]],
        ])

        let markdown = JupyterNotebookMarkdown.markdown(fromNotebookText: text)

        XCTAssertTrue(markdown.contains("line 200\n… 50 more lines\n```"), markdown.suffix(80).description)
        XCTAssertFalse(markdown.contains("line 201"))
        XCTAssertFalse(markdown.contains("```python"), "An empty code cell shows only its output")
    }

    func testAMarkdownCellsAttachedImageShowsFromItsData() throws {
        let gif = Data("GIF89a".utf8).base64EncodedString()
        let text = try notebook(cells: [
            ["cell_type": "markdown", "metadata": [:], "source": "![plot](attachment:plot.gif)",
             "attachments": ["plot.gif": ["image/gif": gif]]],
        ])

        XCTAssertEqual(
            JupyterNotebookMarkdown.markdown(fromNotebookText: text),
            "![plot](data:image/gif;base64,\(gif))\n"
        )
    }

    func testAnNbformat3NotebookReadsItsWorksheet() throws {
        let object: [String: Any] = [
            "nbformat": 3,
            "metadata": ["language": "julia"],
            "worksheets": [["cells": [
                ["cell_type": "heading", "level": 2, "source": "Model"],
                ["cell_type": "code", "input": "fit(x)", "language": "julia",
                 "outputs": [["output_type": "pyout", "text": "42"]]],
            ]]],
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)

        XCTAssertEqual(
            JupyterNotebookMarkdown.markdown(fromNotebookText: text),
            "## Model\n\n```julia\nfit(x)\n```\n\n```output\n42\n```\n"
        )
    }

    func testTextThatIsNotANotebookSaysSo() throws {
        for text in ["", "not json", "[1, 2]", #"{"cells": 3}"#] {
            XCTAssertTrue(
                JupyterNotebookMarkdown.markdown(fromNotebookText: text).hasPrefix("> [!WARNING]"),
                text
            )
        }
        XCTAssertEqual(
            JupyterNotebookMarkdown.markdown(fromNotebookText: try notebook(cells: [])),
            "*This notebook has no cells.*\n"
        )
    }
}
