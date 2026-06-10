import Foundation
import MonknotCore

enum MonknotCaptureCLI {
    static func run(arguments: [String] = CommandLine.arguments) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            printHelp()
            return 0
        }

        do {
            let workspace = try requiredValue(for: "--workspace", in: arguments)
            let sourceURL = value(for: "--url", in: arguments)
            let title = value(for: "--title", in: arguments)
            let text = try textPayload(arguments: arguments)
            let captureURL = try MonknotCaptureURLBuilder().captureURL(
                workspacePath: workspace,
                sourceURL: sourceURL,
                text: text,
                title: title
            )

            if arguments.contains("--print-url") {
                print(captureURL.absoluteString)
                return 0
            }

            return open(captureURL)
        } catch {
            writeError(error.localizedDescription)
            return 64
        }
    }

    private static func textPayload(arguments: [String]) throws -> String? {
        let directText = value(for: "--text", in: arguments)
        let shouldReadStdin = arguments.contains("--stdin")

        guard !(directText != nil && shouldReadStdin) else {
            throw CLIError.multipleTextInputs
        }

        guard shouldReadStdin else {
            return directText
        }

        let data = try FileHandle.standardInput.readToEnd() ?? Data()
        return String(data: data, encoding: .utf8)
    }

    private static func open(_ url: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            writeError(error.localizedDescription)
            return 1
        }
    }

    private static func requiredValue(for flag: String, in arguments: [String]) throws -> String {
        guard let value = value(for: flag, in: arguments) else {
            throw CLIError.missingArgument(flag)
        }
        return value
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        let value = arguments[index + 1]
        return value.hasPrefix("--") ? nil : value
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private static func printHelp() {
        print(
            """
            monknot-capture — send text or URLs into a Monknot workspace inbox

            Usage:
              monknot-capture --workspace <path> --url <https://example.com>
              monknot-capture --workspace <path> --text "Captured text"
              monknot-capture --workspace <path> --url <url> --title "Page title"
              pbpaste | monknot-capture --workspace <path> --stdin
              monknot-capture --workspace <path> --url <url> --print-url

            Options:
              --title TEXT  Override the generated note title.
              --stdin       Read captured text from standard input.
              --print-url   Print the monknot://capture URL instead of opening it.
            """
        )
    }

    enum CLIError: LocalizedError {
        case missingArgument(String)
        case multipleTextInputs

        var errorDescription: String? {
            switch self {
            case .missingArgument(let flag):
                return "Missing required argument: \(flag)."
            case .multipleTextInputs:
                return "Provide only one text input source: --text or --stdin."
            }
        }
    }
}

exit(MonknotCaptureCLI.run())
