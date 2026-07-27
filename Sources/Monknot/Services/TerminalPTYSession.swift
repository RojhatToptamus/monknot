import Darwin
import Foundation

enum TerminalPTYError: LocalizedError {
    case openMasterFailed
    case grantFailed
    case unlockFailed
    case slaveNameFailed
    case openSlaveFailed

    var errorDescription: String? {
        switch self {
        case .openMasterFailed:
            return "Could not open a pseudo-terminal."
        case .grantFailed:
            return "Could not grant pseudo-terminal access."
        case .unlockFailed:
            return "Could not unlock the pseudo-terminal."
        case .slaveNameFailed:
            return "Could not resolve the pseudo-terminal device."
        case .openSlaveFailed:
            return "Could not open the pseudo-terminal device."
        }
    }
}

final class TerminalPTYSession {
    private let outputHandler: @Sendable (String) -> Void
    private let exitHandler: @Sendable (Int32?) -> Void
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var processGroupID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "io.github.rojhattoptamus.monknot.terminal-pty.\(UUID().uuidString)")
    private let queueKey = DispatchSpecificKey<Void>()
    private var didFinish = false

    init(
        outputHandler: @escaping @Sendable (String) -> Void,
        exitHandler: @escaping @Sendable (Int32?) -> Void
    ) {
        self.outputHandler = outputHandler
        self.exitHandler = exitHandler
        ioQueue.setSpecific(key: queueKey, value: ())
    }

    func start(workingDirectory: URL) throws {
        guard childPID <= 0 else { return }

        let shellPath = strdup("/bin/zsh")
        let arg0 = strdup("zsh")
        let arg1 = strdup("-il")
        let cwdPath = strdup(workingDirectory.path)
        defer {
            free(shellPath)
            free(arg0)
            free(arg1)
            free(cwdPath)
        }

        guard let shellPath, let arg0, let arg1, let cwdPath else {
            throw TerminalPTYError.openMasterFailed
        }

        var master: Int32 = -1
        var windowSize = winsize(ws_row: 32, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&master, nil, nil, &windowSize)

        guard pid >= 0 else {
            throw TerminalPTYError.openMasterFailed
        }

        if pid == 0 {
            chdir(cwdPath)
            setenv("TERM", "xterm-256color", 1)
            setenv("COLORTERM", "truecolor", 1)
            setenv("CLICOLOR", "1", 1)
            setenv("MONKNOT_TERMINAL", "1", 1)

            var argv: [UnsafeMutablePointer<CChar>?] = [arg0, arg1, nil]
            execv(shellPath, &argv)
            _exit(127)
        }

        masterFD = master
        childPID = pid
        processGroupID = {
            let groupID = Darwin.getpgid(pid)
            return groupID > 0 ? groupID : pid
        }()
        performOnIOQueueSync {
            didFinish = false
            startReadingOnQueue(masterFD: master)
        }
        waitForChild(pid)
    }

    func write(_ string: String) {
        guard masterFD >= 0, let data = string.data(using: .utf8) else { return }
        ioQueue.async { [weak self] in
            self?.writeOnQueue(data)
        }
    }

    func resize(columns: Int, rows: Int) {
        ioQueue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            var windowSize = winsize(
                ws_row: UInt16(max(1, rows)),
                ws_col: UInt16(max(1, columns)),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            _ = ioctl(self.masterFD, TIOCSWINSZ, &windowSize)
        }
    }

    func stop() {
        performOnIOQueueSync {
            stopOnQueue()
        }
    }

    private func startReadingOnQueue(masterFD: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.readAvailableOutputOnQueue()
        }
        source.setCancelHandler {
            Darwin.close(masterFD)
        }
        readSource = source
        source.activate()
    }

    private func readAvailableOutputOnQueue() {
        guard masterFD >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(masterFD, &buffer, buffer.count)

        if count > 0 {
            outputHandler(String(decoding: buffer.prefix(count), as: UTF8.self))
        } else {
            cancelReadSourceOnQueue()
        }
    }

    private func writeOnQueue(_ data: Data) {
        guard masterFD >= 0 else { return }

        data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }

            var remaining = data.count
            while remaining > 0 {
                let written = Darwin.write(masterFD, pointer, remaining)
                if written > 0 {
                    pointer = pointer.advanced(by: written)
                    remaining -= written
                } else if errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private func waitForChild(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(pid, &status, 0)
            } while result == -1 && errno == EINTR

            let exitCode = result == pid ? Self.exitCode(from: status) : nil
            self?.ioQueue.async { [weak self] in
                self?.finishOnQueue(status: exitCode)
            }
        }
    }

    private func stopOnQueue() {
        guard !didFinish else { return }
        didFinish = true

        let pid = childPID
        let groupID = processGroupID
        childPID = -1
        processGroupID = -1

        if pid > 0 {
            terminateProcess(pid: pid, processGroupID: groupID)
        }

        cancelReadSourceOnQueue()
    }

    private func finishOnQueue(status: Int32?) {
        guard !didFinish else { return }
        didFinish = true
        childPID = -1
        processGroupID = -1
        cancelReadSourceOnQueue()
        exitHandler(status)
    }

    private func cancelReadSourceOnQueue() {
        if let readSource {
            self.readSource = nil
            masterFD = -1
            readSource.cancel()
        } else if masterFD >= 0 {
            Darwin.close(masterFD)
            masterFD = -1
        }
    }

    private func terminateProcess(pid: pid_t, processGroupID: pid_t) {
        let currentProcessGroupID = Darwin.getpgrp()
        if processGroupID > 0, processGroupID != currentProcessGroupID {
            if Darwin.kill(-processGroupID, SIGTERM) == 0 {
                return
            }
        }

        Darwin.kill(pid, SIGTERM)
    }

    private func performOnIOQueueSync(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            ioQueue.sync(execute: work)
        }
    }

    private static func exitCode(from waitStatus: Int32) -> Int32? {
        let signal = waitStatus & 0x7F
        if signal == 0 {
            return (waitStatus >> 8) & 0xFF
        }
        if signal != 0x7F {
            return 128 + signal
        }
        return nil
    }

    deinit {
        stop()
    }
}
