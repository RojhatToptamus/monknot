import Foundation
import MonknotCore

enum MonknotExportCLI {
    static func run(arguments: [String] = CommandLine.arguments) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            printHelp()
            return 0
        }

        if arguments.contains("--stdio") || arguments.contains("--mcp") {
            return runStdioServer()
        }

        if let workspacePath = value(for: "--workspace", in: arguments),
           arguments.contains("--json") {
            return runOneShotExport(workspacePath: workspacePath)
        }

        return runStdioServer()
    }

    private static func runOneShotExport(workspacePath: String) -> Int32 {
        do {
            let request = WorkspaceReadOnlyExportRequest(command: "list_documents", root: workspacePath)
            let requestData = try JSONEncoder().encode(request)
            let response = try WorkspaceReadOnlyExportService().handle(requestData: requestData)
            FileHandle.standardOutput.write(response)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return 0
        } catch {
            writeError(error.localizedDescription)
            return 1
        }
    }

    private static func runStdioServer() -> Int32 {
        let service = WorkspaceReadOnlyExportService()

        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            do {
                let response = try service.handle(requestData: Data(trimmed.utf8))
                FileHandle.standardOutput.write(response)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } catch {
                writeError(localizedDescription(for: error))
                return 1
            }
        }

        return 0
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func localizedDescription(for error: Error) -> String {
        if let exportError = error as? WorkspaceReadOnlyExportService.Error {
            switch exportError {
            case .unsupportedCommand(let command):
                return "Unsupported command: \(command)"
            case .missingQuery:
                return "Missing query for search command."
            case .missingRelativePath:
                return "Missing relativePath for read_file command."
            case .invalidRelativePath(let path):
                return "Invalid relative path: \(path)"
            case .fileNotFound(let path):
                return "File not found: \(path)"
            case .unreadableFile(let path):
                return "File is not readable text: \(path)"
            }
        }
        return error.localizedDescription
    }

    private static func writeError(_ message: String) {
        let payload = ["error": message]
        guard let data = try? JSONEncoder().encode(payload) else { return }
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
    }

    private static func printHelp() {
        let commands = WorkspaceReadOnlyExportService.supportedCommands.joined(separator: ", ")
        print(
            """
            monknot-export — read-only Monknot workspace bridge for agents (stdio JSON lines)

            Usage:
              monknot-export [--stdio|--mcp]
              monknot-export --workspace <path> --json

            Commands (\(commands)):
              {"command":"capabilities","root":"/path/to/workspace"}
              {"command":"list_documents","root":"/path/to/workspace"}
              {"command":"tree","root":"/path/to/workspace"}
              {"command":"search","root":"/path/to/workspace","query":"needle"}
              {"command":"read_file","root":"/path/to/workspace","relativePath":"notes/todo.md"}

            Each request is one JSON object on stdin; each response is one JSON object on stdout.
            """
        )
    }
}

exit(MonknotExportCLI.run())
