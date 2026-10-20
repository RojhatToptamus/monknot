import Foundation

/// Turns a Jupyter notebook (nbformat 3 or 4) into Markdown for the preview: Markdown cells as
/// written, code cells as fenced code in the notebook's language, and each cell's outputs after
/// it. The preview renders HTML from the Markdown renderer only, so HTML outputs show their plain
/// text and images show as `data:` images.
public enum JupyterNotebookMarkdown {
    /// Lines of one text output shown before the rest is summarised, so a long log stays readable.
    public static let maximumOutputLines = 200

    public static func markdown(fromNotebookText text: String) -> String {
        guard let data = text.data(using: .utf8),
              let notebook = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cells = cells(of: notebook)
        else {
            return "> [!WARNING]\n> This file is not a notebook Monknot can read. Switch to Source to see its contents.\n"
        }

        let language = language(of: notebook)
        var blocks: [String] = []
        for cell in cells {
            let source = joined(cell["source"] ?? cell["input"])
            switch cell["cell_type"] as? String {
            case "heading":
                // nbformat 3 keeps a heading's level beside its text.
                let level = min(max(cell["level"] as? Int ?? 1, 1), 6)
                blocks.append(String(repeating: "#", count: level) + " " + source.trimmingCharacters(in: .whitespacesAndNewlines))
            case "markdown":
                let markdown = replacingAttachments(in: source, attachments: cell["attachments"])
                if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(markdown.trimmingCharacters(in: .newlines))
                }
            case "code":
                if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(fenced(source, info: language))
                }
                let outputs = cell["outputs"] as? [[String: Any]] ?? []
                blocks.append(contentsOf: outputs.compactMap(markdown(forOutput:)))
            default:
                if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(fenced(source, info: ""))
                }
            }
        }
        guard !blocks.isEmpty else { return "*This notebook has no cells.*\n" }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// nbformat 4 keeps cells at the top level; nbformat 3 inside its first worksheet.
    private static func cells(of notebook: [String: Any]) -> [[String: Any]]? {
        if let cells = notebook["cells"] as? [[String: Any]] {
            return cells
        }
        let worksheets = notebook["worksheets"] as? [[String: Any]]
        return worksheets?.first?["cells"] as? [[String: Any]]
    }

    private static func language(of notebook: [String: Any]) -> String {
        let metadata = notebook["metadata"] as? [String: Any]
        let kernel = metadata?["kernelspec"] as? [String: Any]
        let info = metadata?["language_info"] as? [String: Any]
        let name = (kernel?["language"] as? String) ?? (info?["name"] as? String) ?? (metadata?["language"] as? String)
        return name?.lowercased() ?? "python"
    }

    private static func markdown(forOutput output: [String: Any]) -> String? {
        switch output["output_type"] as? String {
        case "stream":
            return textOutput(joined(output["text"]))
        case "error", "pyerr":
            let traceback = (output["traceback"] as? [String]).map { $0.joined(separator: "\n") }
            let summary = [output["ename"] as? String, output["evalue"] as? String]
                .compactMap { $0 }
                .joined(separator: ": ")
            return textOutput(withoutTerminalEscapes(traceback ?? summary))
        case "execute_result", "display_data", "pyout":
            // nbformat 4 keeps the representations in `data`; nbformat 3 on the output itself.
            let data = output["data"] as? [String: Any] ?? output
            return markdown(forData: data)
        default:
            return nil
        }
    }

    private static func markdown(forData data: [String: Any]) -> String? {
        for (type, key) in [("image/png", "png"), ("image/jpeg", "jpeg"), ("image/gif", "gif")] {
            if let base64 = data[type] ?? data[key] {
                let encoded = joined(base64).filter { !$0.isWhitespace }
                return "![Output](data:\(type);base64,\(encoded))"
            }
        }
        if let svg = data["image/svg+xml"] ?? data["svg"] {
            let encoded = Data(joined(svg).utf8).base64EncodedString()
            return "![Output](data:image/svg+xml;base64,\(encoded))"
        }
        if let markdown = data["text/markdown"] {
            return joined(markdown)
        }
        if let plain = data["text/plain"] ?? data["text"] {
            return textOutput(joined(plain))
        }
        if data["text/html"] != nil || data["html"] != nil {
            return "*This output is HTML, which Monknot does not show.*"
        }
        return nil
    }

    private static func textOutput(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return nil }
        let lines = trimmed.components(separatedBy: "\n")
        guard lines.count > maximumOutputLines else { return fenced(trimmed, info: "output") }
        let shown = lines.prefix(maximumOutputLines).joined(separator: "\n")
        return fenced(shown + "\n… \(lines.count - maximumOutputLines) more lines", info: "output")
    }

    /// A fence longer than any run of backticks in `text`, so code holding ``` stays inside it.
    private static func fenced(_ text: String, info: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(info)\n\(text.trimmingCharacters(in: .newlines))\n\(fence)"
    }

    /// Notebook text is a string or a list of lines that keep their own line endings.
    private static func joined(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let lines = value as? [String] {
            return lines.joined()
        }
        return ""
    }

    /// Points `attachment:name` images in a Markdown cell at the data the cell carries.
    private static func replacingAttachments(in markdown: String, attachments: Any?) -> String {
        guard let attachments = attachments as? [String: [String: Any]] else { return markdown }
        var result = markdown
        for (name, representations) in attachments {
            guard let (type, value) = representations.first(where: { $0.key.hasPrefix("image/") }) else { continue }
            let encoded = joined(value).filter { !$0.isWhitespace }
            result = result.replacingOccurrences(of: "attachment:\(name)", with: "data:\(type);base64,\(encoded)")
        }
        return result
    }

    /// Tracebacks carry terminal colour codes such as `ESC[0;31m`.
    private static func withoutTerminalEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
