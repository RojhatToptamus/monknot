import Combine
import Foundation

@MainActor
final class TerminalSessionStore: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRunning = false
    @Published private(set) var workingDirectory: URL
    @Published private(set) var outputRevision = 0

    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private let maxTranscriptLength = 240_000
    private let trimmedTranscriptLength = 180_000
    private let maxPendingOutputBeforeFlush = 32_000
    private let outputFlushIntervalNanoseconds: UInt64 = 16_000_000
    private var ptySession: TerminalPTYSession?
    private var sessionGeneration = 0
    private var pendingOutput = ""
    private var outputFlushTask: Task<Void, Never>?

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
        pendingOutput = ""
        outputFlushTask?.cancel()
        outputFlushTask = nil
        isRunning = true
        sessionGeneration += 1
        let generation = sessionGeneration

        let session = TerminalPTYSession(
            outputHandler: { [weak self] output in
                Task { @MainActor in
                    self?.enqueueOutput(output, generation: generation)
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
        pendingOutput = ""
        outputFlushTask?.cancel()
        outputFlushTask = nil
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
        flushPendingOutput(generation: sessionGeneration)
        sessionGeneration += 1
        ptySession?.stop()
        ptySession = nil
        pendingOutput = ""
        outputFlushTask?.cancel()
        outputFlushTask = nil
        isRunning = false
    }

    private func enqueueOutput(_ rawOutput: String, generation: Int) {
        guard generation == sessionGeneration else { return }

        pendingOutput += rawOutput

        if pendingOutput.count >= maxPendingOutputBeforeFlush {
            outputFlushTask?.cancel()
            flushPendingOutput(generation: generation)
            return
        }

        guard outputFlushTask == nil else { return }
        let flushInterval = outputFlushIntervalNanoseconds
        outputFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: flushInterval)
            } catch {
                return
            }

            self?.flushPendingOutput(generation: generation)
        }
    }

    private func flushPendingOutput(generation: Int) {
        outputFlushTask = nil
        guard generation == sessionGeneration else {
            pendingOutput = ""
            return
        }
        guard !pendingOutput.isEmpty else { return }

        transcript += pendingOutput
        pendingOutput = ""
        if transcript.count > maxTranscriptLength {
            transcript = String(transcript.suffix(trimmedTranscriptLength))
        }
        outputRevision += 1
    }

    private func handleExit(_ status: Int32?, generation: Int) {
        guard generation == sessionGeneration else { return }

        flushPendingOutput(generation: generation)
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
        outputFlushTask?.cancel()
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
