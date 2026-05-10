import Combine
import Foundation

enum TerminalSessionStatus: Equatable {
    case idle
    case running
    case exited(Int32?)
    case failed(String)
}

@MainActor
final class TerminalSessionStore: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRunning = false
    @Published private(set) var workingDirectory: URL
    @Published private(set) var outputRevision = 0
    @Published private(set) var status: TerminalSessionStatus = .idle

    static let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private let maxTranscriptLength = 240_000
    private let trimmedTranscriptLength = 180_000
    private let maxPendingOutputBeforeFlush = 32_000
    private let outputFlushIntervalNanoseconds: UInt64 = 16_000_000
    private var ptySession: TerminalPTYSession?
    private var sessionGeneration = 0
    private var pendingOutput = ""
    private var outputFlushTask: Task<Void, Never>?

    init(initialDirectory: URL? = nil) {
        workingDirectory = Self.resolvedDirectory(initialDirectory) ?? Self.homeDirectory
    }

    func setDefaultDirectory(_ url: URL?) {
        guard ptySession == nil, status == .idle else { return }
        guard let directory = Self.resolvedDirectory(url) else { return }
        workingDirectory = directory
    }

    func startIfNeeded() {
        startIfNeeded(in: nil)
    }

    func startIfNeeded(in directory: URL?) {
        guard ptySession == nil else { return }
        guard status == .idle else { return }

        workingDirectory = Self.resolvedDirectory(directory ?? workingDirectory) ?? workingDirectory
        transcript = ""
        pendingOutput = ""
        outputFlushTask?.cancel()
        outputFlushTask = nil
        isRunning = true
        status = .running
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
            status = .failed(error.localizedDescription)
            outputRevision += 1
        }
    }

    func restart() {
        restart(in: workingDirectory)
    }

    func restart(in directory: URL?) {
        workingDirectory = Self.resolvedDirectory(directory) ?? workingDirectory
        sessionGeneration += 1
        ptySession?.stop()
        ptySession = nil
        transcript = ""
        pendingOutput = ""
        outputFlushTask?.cancel()
        outputFlushTask = nil
        isRunning = false
        status = .idle
        outputRevision += 1
        startIfNeeded()
    }

    func send(_ text: String) {
        startIfNeeded()
        guard isRunning else { return }
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
        status = .idle
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
        self.status = .exited(status)
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

    static func resolvedDirectory(_ url: URL?) -> URL? {
        guard let url else { return nil }

        let standardizedURL = url.standardizedFileURL
        var isDirectory = ObjCBool(false)

        if FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? standardizedURL : standardizedURL.deletingLastPathComponent()
        }

        let parentURL = standardizedURL.deletingLastPathComponent()
        var parentIsDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &parentIsDirectory),
           parentIsDirectory.boolValue {
            return parentURL
        }

        return nil
    }
}
