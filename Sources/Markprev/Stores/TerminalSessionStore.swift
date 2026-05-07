import Combine
import Foundation

struct TerminalLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case command
        case output
        case status
        case error
    }

    let id = UUID()
    let kind: Kind
    let text: String
}

@MainActor
final class TerminalSessionStore: ObservableObject {
    @Published private(set) var lines: [TerminalLine] = []
    @Published private(set) var isRunning = false
    @Published private(set) var workingDirectory: URL
    @Published private(set) var completionCount = 0

    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    init(initialDirectory: URL? = nil) {
        workingDirectory = initialDirectory ?? homeDirectory
    }

    var prompt: String {
        let user = NSUserName().isEmpty ? "user" : NSUserName()
        let host = Self.shortHostName()
        return "\(user)@\(host) \(workingDirectory.lastPathComponent) %"
    }

    func setDefaultDirectory(_ url: URL?) {
        guard lines.isEmpty, !isRunning else { return }
        workingDirectory = url ?? homeDirectory
    }

    func submit(_ rawCommand: String) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !isRunning else { return }

        lines.append(TerminalLine(kind: .command, text: "\(prompt) \(command)"))

        if handleBuiltIn(command) {
            return
        }

        isRunning = true
        let directory = workingDirectory

        Task {
            let result = await TerminalCommandRunner.run(command: command, workingDirectory: directory)
            append(result: result)
        }
    }

    private func handleBuiltIn(_ command: String) -> Bool {
        if command == "clear" {
            lines.removeAll()
            completionCount += 1
            return true
        }

        if command == "pwd" {
            lines.append(TerminalLine(kind: .output, text: workingDirectory.path))
            completionCount += 1
            return true
        }

        if command == "cd" || command.hasPrefix("cd ") {
            changeDirectory(command)
            completionCount += 1
            return true
        }

        return false
    }

    private func changeDirectory(_ command: String) {
        let rawPath = command == "cd" ? "~" : String(command.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let target = resolvedDirectory(for: rawPath)

        guard FileManager.default.directoryExists(at: target) else {
            lines.append(TerminalLine(kind: .error, text: "cd: no such directory: \(rawPath)"))
            return
        }

        workingDirectory = target.standardizedFileURL
    }

    private func resolvedDirectory(for rawPath: String) -> URL {
        if rawPath == "~" || rawPath.isEmpty {
            return homeDirectory
        }

        if rawPath.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(rawPath.dropFirst(2)))
        }

        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath)
        }

        return workingDirectory.appendingPathComponent(rawPath)
    }

    private func append(result: TerminalCommandResult) {
        let trimmedOutput = result.output.trimmingCharacters(in: .newlines)
        if !trimmedOutput.isEmpty {
            lines.append(TerminalLine(kind: result.exitCode == 0 ? .output : .error, text: trimmedOutput))
        }

        if result.exitCode != 0 {
            lines.append(TerminalLine(kind: .status, text: "Process exited with status \(result.exitCode)"))
        }

        isRunning = false
        completionCount += 1
    }

    private static func shortHostName() -> String {
        let rawHost = ProcessInfo.processInfo.hostName
            .split(separator: ".")
            .first
            .map(String.init)
            ?? Host.current().localizedName
            ?? "mac"

        let compact = rawHost
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".local", with: "")

        return compact.isEmpty ? "mac" : compact
    }
}

private extension FileManager {
    func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
