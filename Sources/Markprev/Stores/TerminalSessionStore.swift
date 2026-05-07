import Combine
import Foundation

@MainActor
final class TerminalSessionStore: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRunning = false
    @Published private(set) var workingDirectory: URL
    @Published private(set) var outputRevision = 0

    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private var ptySession: TerminalPTYSession?
    private var sessionGeneration = 0

    init(initialDirectory: URL? = nil) {
        workingDirectory = Self.resolvedDirectory(initialDirectory, fallback: homeDirectory)
    }

    func setDefaultDirectory(_ url: URL?) {
        guard ptySession == nil else { return }
        workingDirectory = Self.resolvedDirectory(url, fallback: homeDirectory)
    }

    func startIfNeeded() {
        guard ptySession == nil else { return }

        transcript = ""
        isRunning = true
        sessionGeneration += 1
        let generation = sessionGeneration

        let session = TerminalPTYSession(
            outputHandler: { [weak self] output in
                Task { @MainActor in
                    self?.append(output, generation: generation)
                }
            },
            exitHandler: { [weak self] status in
                Task { @MainActor in
                    self?.handleExit(status, generation: generation)
                }
            }
        )

        do {
            try session.start(workingDirectory: workingDirectory)
            ptySession = session
        } catch {
            transcript = "markprev: \(error.localizedDescription)\n"
            isRunning = false
            outputRevision += 1
        }
    }

    func startOrRestartIfNeeded(in directory: URL?) {
        let resolvedDirectory = Self.resolvedDirectory(directory, fallback: homeDirectory)

        guard ptySession != nil else {
            workingDirectory = resolvedDirectory
            startIfNeeded()
            return
        }

        guard workingDirectory.standardizedFileURL != resolvedDirectory.standardizedFileURL else {
            return
        }

        restart(in: resolvedDirectory)
    }

    func restart() {
        restart(in: workingDirectory)
    }

    func restart(in directory: URL?) {
        workingDirectory = Self.resolvedDirectory(directory, fallback: homeDirectory)
        sessionGeneration += 1
        ptySession?.stop()
        ptySession = nil
        transcript = ""
        outputRevision += 1
        startIfNeeded()
    }

    func send(_ text: String) {
        startIfNeeded()
        ptySession?.write(text)
    }

    func resize(columns: Int, rows: Int) {
        ptySession?.resize(columns: columns, rows: rows)
    }

    func stop() {
        sessionGeneration += 1
        ptySession?.stop()
        ptySession = nil
        isRunning = false
    }

    private func append(_ rawOutput: String, generation: Int) {
        guard generation == sessionGeneration else { return }

        transcript += rawOutput
        if transcript.count > 240_000 {
            transcript = String(transcript.suffix(180_000))
        }
        outputRevision += 1
    }

    private func handleExit(_ status: Int32?, generation: Int) {
        guard generation == sessionGeneration else { return }

        isRunning = false
        ptySession = nil

        if let status {
            transcript += "\n[Process exited with status \(status)]\n"
        } else {
            transcript += "\n[Process exited]\n"
        }

        outputRevision += 1
    }
    deinit {
        ptySession?.stop()
    }

    private static func resolvedDirectory(_ url: URL?, fallback: URL) -> URL {
        guard let url else { return fallback }

        let standardizedURL = url.standardizedFileURL
        var isDirectory = ObjCBool(false)

        if FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? standardizedURL : standardizedURL.deletingLastPathComponent()
        }

        return fallback
    }
}
