import Foundation

struct TerminalCommandResult: Sendable {
    let output: String
    let exitCode: Int32
}

enum TerminalCommandRunner {
    static func run(command: String, workingDirectory: URL) async -> TerminalCommandResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = pipe
            process.standardError = pipe

            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "xterm-256color"
            environment["CLICOLOR"] = "1"
            process.environment = environment

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                return TerminalCommandResult(
                    output: String(data: data, encoding: .utf8) ?? "",
                    exitCode: process.terminationStatus
                )
            } catch {
                return TerminalCommandResult(
                    output: "markprev: \(error.localizedDescription)\n",
                    exitCode: 127
                )
            }
        }.value
    }
}
