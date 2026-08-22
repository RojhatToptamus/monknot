import Foundation

public enum WorkspaceGitFileStatus: String, Sendable, Equatable {
    case modified
    case added
    case deleted
    case untracked
    case renamed
}

public struct WorkspaceGitStatusService: Sendable {
    private let processLauncher: @Sendable (URL) -> String?

    public init() {
        self.processLauncher = launchGitStatus
    }

    public init(processLauncher: @escaping @Sendable (URL) -> String?) {
        self.processLauncher = processLauncher
    }

    public func statusMap(workspaceURL: URL) -> [String: WorkspaceGitFileStatus] {
        guard let output = processLauncher(workspaceURL.standardizedFileURL) else {
            return [:]
        }

        var statuses: [String: WorkspaceGitFileStatus] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.count >= 4 else { continue }
            let statusCode = String(line.prefix(2))
            let rawPath = String(line.dropFirst(3))
            let relativePath = normalizedPath(rawPath, statusCode: statusCode)
            guard !relativePath.isEmpty else { continue }

            if let status = parseStatusCode(statusCode) {
                statuses[relativePath] = status
            }
        }

        return statuses
    }

    private func parseStatusCode(_ code: String) -> WorkspaceGitFileStatus? {
        if code == "??" {
            return .untracked
        }

        if code.contains("R") {
            return .renamed
        }
        if code.contains("D") {
            return .deleted
        }
        if code.contains("A") {
            return .added
        }
        if code.contains("M") {
            return .modified
        }

        return nil
    }

    private func normalizedPath(_ rawPath: String, statusCode: String) -> String {
        let selectedPath: String
        if statusCode.contains("R"), let arrow = rawPath.range(of: " -> ", options: .backwards) {
            selectedPath = String(rawPath[arrow.upperBound...])
        } else {
            selectedPath = rawPath
        }
        guard selectedPath.first == "\"", selectedPath.last == "\"",
              let data = selectedPath.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(
                  with: data,
                  options: .fragmentsAllowed
              ) as? String else {
            return selectedPath
        }
        return decoded
    }
}

private let launchGitStatus: @Sendable (URL) -> String? = { workspaceURL in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", workspaceURL.path, "status", "--porcelain"]
    process.currentDirectoryURL = workspaceURL

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return nil
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }

    return String(data: data, encoding: .utf8)
}
